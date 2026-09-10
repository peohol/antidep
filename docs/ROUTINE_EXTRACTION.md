# Modell-leddet kjørt av en Claude Code Routine

**Status:** operativ veiledning  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md), [`EVIDENCE_PIPELINE.md`](./EVIDENCE_PIPELINE.md)

Dette dokumentet sier hvordan modell-leddet i evidenspipelinen kjøres av en
Claude Code Routine, og hvorfor det er satt opp slik det er.

Det handler om **ett** ledd: det som leser én kilde og foreslår de strukturerte
verdiene for ett evidensfunn. Alt før og etter er uendret.

---

## 1. Hvorfor Routines, og ikke et modell-API i Antidep

Antidep har ingen innebygd kobling mot Anthropic, OpenAI eller noen annen
betalt modelleverandør, og skal ikke få det uten et konkret behov. Modellarbeidet
kjøres i stedet av en Claude Code Routine, innenfor et oppsett som allerede
finnes.

Det gir tre ting samtidig:

- **Ingen ny leverandørkonto og ingen ny kostnadslinje** for å kunne kjøre,
  prøve eller regresjonsteste kjeden.
- **Leverandøruavhengighet i praksis.** Antidep definerer oppdraget,
  datakontrakten og kontrollene. Routinen er bare aktøren som utfører
  modellarbeidet, og kan byttes ut med en annen aktør — et menneske, ChatGPT,
  et innebygd leverandøradapter — uten at noe annet i kjeden endres
  (`ANTIDEP_CONSTITUTION.md` §20, `EVIDENCE_PIPELINE.md` §66).
- **Ingen egen agentrammeverkskode i Antidep.** Orkestreringen — hva som kjøres
  når, hva som skjer etterpå — er Routinens ansvar. Antidep bidrar med
  kommandoene, filformene og kontrollene.

Routinen får **ingen** rettigheter Antidep ikke allerede har gitt et ledd i
kjeden. Den kan lese en kilde og skrive filer. Den kan ikke skrive en rad.

---

## 2. Flyten

```text
registrert kildeversjon
  → ekstraksjonsoppdrag            (en kvalifisert redaktør avgrenser)
  → npm run agent:draft-extraction --open
  → Claude Code leser prompt.txt og skriver svar.json
  → npm run agent:draft-extraction --close
        form-, katalog- og ordretthetskontroll
  → forslag.json
  → npm run agent:extract-evidence   (registrering, egen identitet)
  → npm run agent:verify-extraction  (separat maskinell kontroll, egen identitet)
  → menneskelig kontroll og godkjenning før publisering
```

Ingen av leddene faller bort fordi en Routine kjører det første. Kjeden er den
samme; den har fått en aktør i forkant.

---

## 3. To Routines, ikke én

Det anbefalte oppsettet er **to** Routines, og skillet er en sikkerhetsgrense og
ikke en oppdeling av bekvemmelighet.

| Routine | Hva den gjør | Hva miljøet skal inneholde |
| --- | --- | --- |
| **A — modell-leddet** | Åpner kjøringen, leser kilden, skriver svaret, lukker kjøringen | **Ingen** agentlegitimasjon |
| **B — registrering og kontroll** | Registrerer forslaget og kjører den deterministiske kontrollen | `.env.agent.local` med ekstraksjonsagentens og verifikatorens legitimasjon |

Grunnen står i `EVIDENCE_PIPELINE.md` §63: et ledd som tar imot utrygt eksternt
innhold i en modellkontekst, skal ikke samtidig ha tilgang til hemmeligheten som
kan skrive en rad. Routine A leser en artikkel Antidep ikke kontrollerer.
Routine B leser bare en fil Antidep selv har skrevet, og kjører to kommandoer på
den.

Grensen er håndhevet og ikke bare anbefalt: `npm run agent:draft-extraction`
nekter å kjøre dersom en agenthemmelighet står i miljøet, og feilmeldingen
oppgir kommandoen som fjerner den for den ene kjøringen.

**Restrisikoen, sagt rett ut.** En Claude Code-sesjon har et skall. Kjøres begge
Routinene i den samme sesjonen, kan en modell som har lest en artikkel med noe
instruksjonslignende i seg, i prinsippet kjøre registreringskommandoen på en fil
den skrev selv, uten å gå veien om `--close`. Det ville fortsatt ikke gitt en
publisert påstand — registreringen henter kildeversjonen på nytt, krever at
fingeravtrykket er den registrerte, prøver hvert utdrag ordrett, og hele den
maskinelle og menneskelige kontrollkjeden står igjen etterpå — men avgrensningen
mot katalogen ville vært omgått. To Routines fjerner den muligheten, fordi
Routine A ikke har noen hemmelighet å bruke.

---

## 4. Før Routinen kan kjøre: oppdraget

Modell-leddet kan ikke slå opp i databasen, og skal ikke kunne det. Hvilket
virkestoff og hvilket endepunkt et funn gjelder, er en **faglig avgrensning** en
kvalifisert redaktør gjør, og den leveres som en fil.

Se [`assignments/README.md`](../assignments/README.md) for hvordan et oppdrag
lages og hvor verdiene står. Kort:

```json
{
  "assignment_version": "antidep/extraction-assignment@1",
  "source_id": "…",
  "source_version_id": "…",
  "retrieved_from": "https://…",
  "content_hash": "sha256:…",
  "drugs": [{ "drug_id": "…", "label": "sertralin" }],
  "outcomes": [{ "outcome_concept_id": "…", "label": "vektendring" }],
  "populations": []
}
```

Dette er det eneste steget som krever et menneske med `editor`-rolle, og det er
med hensikt.

---

## 5. Routine A: modell-leddet

### 5.1 Kommandoene

```bash
npm run agent:draft-extraction -- --assignment assignments/<navn>.json --open
# Claude Code leser prompt.txt og skriver svar.json
npm run agent:draft-extraction -- --assignment assignments/<navn>.json --close
```

`--status` sier hvor kjøringen står, uten å hente noe og uten å skrive noe.

Kjøremappa utledes av oppdragsfilen — `assignments/fava-2000.json` gir
`assignments/fava-2000/` — og filnavnene i den er faste. Routinen skal ikke
velge en katalog, et filnavn, et modelladapter eller en promptmalversjon.

### 5.2 Filene i kjøremappa

| Fil | Hvem skriver den | Hva den er |
| --- | --- | --- |
| `kjoring.json` | `--open` og `--close` | Tilstanden: hvilken kildeversjon, hvilket forespørselsavtrykk, hvor kjøringen står |
| `prompt.txt` | `--open` | Nøyaktig det modellen skal lese. Kildeteksten står mellom to markører, og alt mellom dem er data |
| `svar.json` | **aktøren** | Modellens svar |
| `forslag.json` | `--close` | Ekstraksjonsforslaget, når svaret holdt mål |
| `opptak.json` | `--close` | Svaret bundet til forespørselens avtrykk, slik kjøringen kan spilles av igjen uten en modell |

Alt sammen er gitignorert lokal arbeidsdata.

### 5.3 Svaret

```json
{
  "answer_version": "antidep/model-answer@1",
  "request_digest": "sha256:…",
  "identity": { "provider": "anthropic", "model": "claude-code", "model_version": "…" },
  "answered_at": "2026-09-10T09:12:00Z",
  "draft": { "extraction": { }, "field_groundings": [] }
}
```

- `request_digest` står allerede i malen `--open` la igjen. Den skal kopieres
  uendret. Den binder svaret til nøyaktig den kildeteksten, den katalogen og den
  promptmalen som ble spurt om — og et svar med et annet avtrykk lukkes ikke inn
  i denne kjøringen.
- `identity` er **hvem som faktisk svarte**. Verdiene registreres som premissene
  utkastet ble laget under, og en plassholder som blir stående, avvises framfor å
  bli en usann proveniens.
- `answered_at` er tidspunktet aktøren svarte, ikke tidspunktet kjøringen ble
  lukket. Utelates det, brukes lukketidspunktet, som er en øvre grense.
- `draft` er svaret som JSON-objekt. Alternativt kan `completion` bære svaret som
  ordrett tekst — nøyaktig én av de to.

### 5.4 Hva `--close` kontrollerer

1. **Formen.** Svaret må være kontrakten i
   `proposals/extraction-proposal.schema.json`, med lukkede vokabularer og uten
   ukjente felter.
2. **Katalogen.** Hver identifikator må stå i oppdraget.
3. **Ordretthet.** Hvert `source_excerpt` og et eventuelt `source_quote` må stå
   ordrett i representasjonen, som hentes på nytt.

Holder svaret ikke mål, skrives **ingen** fil. Kjøringen står som avvist med en
begrunnelse, og Routinen kan skrive et rettet svar i den samme svarfilen og kjøre
`--close` om igjen.

### 5.5 Avbrutte kjøringer

Begge stegene er idempotente, og tilstanden ligger på disk. En Routine som blir
avbrutt, kan kjøre den samme kommandoen om igjen:

- `--open` på en mappe som venter på svar, skriver den samme prompten og lar et
  svar som allerede er lagt inn, stå.
- `--open` på en mappe som allerede har et forslag, gjør ingenting.
- `--close` på en kjøring som allerede er lukket, gjør ingenting.
- `--close` på en kjøring som ble avbrutt før forslaget ble skrevet, lager det.

Endres kilden, oppdraget eller promptmalen mellom de to stegene, får
forespørselen et annet avtrykk. Da gjelder ikke det gamle svaret, og kjøringen
sier fra framfor å lukke et svar som ble lest ut av en annen tekst.

---

## 6. Routine B: registrering og kontroll

```bash
npm run agent:extract-evidence -- --proposal assignments/<navn>/forslag.json
npm run agent:verify-extraction
```

Den første registrerer forslaget under ekstraksjonsagentens identitet, henter
kildeversjonen på nytt og prøver hvert utdrag ordrett igjen. Den andre kjører den
deterministiske ekstraksjonskontrollen under verifikatorens **egen** identitet —
generering og verifikasjon er to operasjoner, av to aktører
(`ANTIDEP_CONSTITUTION.md` §10, §11).

Legitimasjonen settes som beskrevet i
[`../supabase/README.md`](../supabase/README.md), avsnittet «Legitimasjon til
agentidentiteten».

Etter dette er funnet klart for den menneskelige kontrollen i appen. Ingenting
publiseres uten den.

---

## 7. Slik settes Routinen opp

Selve opprettelsen av en Claude Code Routine skjer utenfor repoet. Prompten er
ferdig skrevet og ligger her:

- **[`.claude/routines/ekstraksjonsoppdrag.md`](../.claude/routines/ekstraksjonsoppdrag.md)**
  — lim innholdet inn som Routinens prompt.

Prompten er kort med vilje: den peker på ferdigheten
[`.claude/skills/ekstraksjon/SKILL.md`](../.claude/skills/ekstraksjon/SKILL.md),
som ligger i repoet og derfor følger med hver endring av arbeidsflyten. Da kan
ikke Routinen og repoet komme i utakt.

Anbefalt oppsett:

- **Routine A** kjøres på forespørsel med oppdragsfilen som eneste variabel.
  Miljøet skal ikke inneholde agentlegitimasjon.
- **Routine B** kjøres etter A, i et miljø med `.env.agent.local`.

---

## 8. Hva som fortsatt krever et menneske

Alt som krevde det før:

- **Oppdraget.** Hvilken kilde, hvilket virkestoff, hvilket endepunkt.
- **Den menneskelige ekstraksjonskontrollen.** Felt for felt, mot kilden.
- **Claim-arbeidet og den faglige vurderingen.**
- **Publiseringsgodkjenningen.**

Modell-leddet produserer et **forslag**. Et forslag er ikke kunnskap
(`ANTIDEP_CONSTITUTION.md` §10, §11, §12).
