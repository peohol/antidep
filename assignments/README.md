# Oppdrag til modell-leddet

Et **oppdrag** er det modell-leddet får vite som ikke står i artikkelen:
hvilken kildeversjon det skal lese, og hvilke virkestoff, endepunkt og
populasjoner funnet kan peke på.

Modell-leddet leser oppdraget og kilden, og skriver ett **ekstraksjonsforslag**.
Det er alt det gjør. Det har ingen databasetilgang, ingen
agentlegitimasjon og ingen skrivevei: forslaget registreres etterpå av
`npm run agent:extract-evidence`, som kjører hele den deterministiske kontrollen
på nytt.

Filene her er **lokal inndata**. De er gitignorert, deployes ikke, og er ikke
faglig innhold.

## 1. Lag oppdraget

Én kommando. Ingen uuid, ingen hash og ingen JSON skrives for hånd.

**Har du fulltekst-PDF-en?** Da registreres fullteksten av den, i samme slengen:

```bash
npm run editor:assignment -- \
  --source "Fava" \
  --pdf ~/artikler/fava-2000.pdf \
  --retrieved-from "https://doi.org/10.4088/jcp.v61n1109" \
  --drug sertralin \
  --outcome vektendring \
  --population "voksne med depressiv lidelse"
```

**Skal oppdraget gjelde en kildeversjon som allerede er registrert?** Da sløyfes
`--pdf`, og den nyeste brukbare versjonen velges — eventuelt av den typen
`--representation` ber om:

```bash
npm run editor:assignment -- --source "Versiani" --representation abstract \
  --drug mirtazapin --outcome vektendring
```

Kommandoen skriver ut hva den fant og hva den valgte, og legger oppdraget i
`assignments/`. `--help` viser alle valgene.

Dette er det eneste steget som krever et menneske med `editor`-rolle, og det er
med hensikt: hvilken artikkel og hvilken avgrensning et funn gjelder, er en
faglig avgjørelse.

### Miljøet kommandoen trenger

`ANTIDEP_SUPABASE_URL`, `ANTIDEP_SUPABASE_PUBLISHABLE_KEY` og redaktørens egen
innlogging (`ANTIDEP_EDITOR_EMAIL`, `ANTIDEP_EDITOR_PASSWORD`) — se
`.env.example`. Med `--pdf` trengs i tillegg `pdftotext` fra poppler
(`apt-get install poppler-utils`, eller `brew install poppler`).

## 2. Hva som faktisk skjer med en PDF

Antidep lagrer **ikke** dokumentet. Det som skjer, er:

1. PDF-en leses, og bytene sendes til
   `api.create_source_version_from_document(...)`.
2. **Databasen** beregner sha256 av bytene, størrelsen, og leser mediatypen av
   dokumentets egen signatur. Ingen av de tre er noe kalleren oppgir — de er
   observasjoner, ikke påstander (migrasjon 003e).
3. Teksten hentes ut med `pdftotext`, og **oppskriften** — verktøy, versjon,
   argumenter — lagres sammen med sha256 av teksten.
4. PDF-en legges i `documents/` under fingeravtrykket sitt, slik at resten av
   kjeden finner den igjen uten et filnavn (`../documents/README.md`).

Kontrakten utad er dermed etterprøvbar av hvem som helst med sin egen lovlige
kopi:

```bash
sha256sum artikkel.pdf                                          # document_sha256
pdftotext -layout -enc UTF-8 -eol unix artikkel.pdf - | sha256sum   # content_hash
```

Hvert eneste ledd videre i kjeden gjør nøyaktig det samme, hver gang. En
kildeversjon som er utledet av et dokument, hentes **aldri** over nett — og en
som er hentet over nett, hentes aldri fra et dokument. Uten den regelen kunne et
sammendrag fra PubMed blitt kontrollgrunnlaget for en ekstraksjon registrert som
fulltekst.

## 3. Hvorfor oppdraget kommer fra databasen

Oppdraget er en **tiltrodd** inndata: registreringen kontrollerer forslaget mot
det, så oppdraget er halvparten av kontrollen. Et oppdrag satt sammen av verdier
noen har kopiert, ville vært en kontroll mot en kopi — og en kildebinding med
adressen fra én rad og fingeravtrykket fra en annen ville sendt hele kjeden til
feil tekst.

`api.build_extraction_assignment(...)` (migrasjon 007i) tar derfor imot
**kanoniske navn** og svarer med hele oppdraget. Et navn som ikke finnes i
katalogen, gir en avvisning som navngir verdien — aldri et oppdrag med én
avgrensning mindre enn du ba om.

Modell-leddet får fortsatt bare filen. Det kan ikke slå opp i databasen, og skal
ikke kunne det: det leser utrygt eksternt innhold, og et ledd som gjør det, skal
ikke samtidig ha en leseflate inn i Antidep.

## 4. Slik ser et oppdrag ut

Se `eksempel-syntetisk-oppdrag.json`. Kort fortalt:

- **hvilken kildeversjon** som skal leses (`source_id`, `source_version_id`,
  `retrieved_from`, `content_hash`),
- **`document`** — originaldokumentet versjonen er utledet av, med oppskriften
  teksten ble hentet ut med. `null` når representasjonen er teksten på adressen,
- **`drugs`** og **`outcomes`** — minst ett av hver, med id og navn,
- **`populations`** — kan være tom. Passer ingen registrert populasjon, sier
  forslaget det i `population_availability` framfor å velge en som nesten
  passer.

Navnene ved siden av id-ene er for modellens skyld. Det er id-en som registreres.

Et ukjent felt er en feil, ikke noe som ignoreres.

## 5. Kjør modell-leddet

To kommandoer med en fil imellom — den veien en Claude Code Routine kjører:

```bash
npm run agent:draft-extraction -- --assignment assignments/fava-2000.json --open
```

Kommandoen skaffer representasjonen, krever at fingeravtrykket stemmer, og
legger igjen en **kjøremappe** — `assignments/fava-2000/`, utledet av
oppdragsfilen:

| Fil            | Hva den er                                                                    |
| -------------- | ----------------------------------------------------------------------------- |
| `kjoring.json` | Tilstanden: kildeversjonen, forespørselens fingeravtrykk, hvor kjøringen står |
| `prompt.txt`   | Nøyaktig det modellen skal få se                                              |
| `svar.json`    | Malen aktøren som utfører modellarbeidet, fyller ut                           |

Den skriver ingenting i databasen.

## 6. Legg inn svaret

Aktøren — en Claude Code Routine, ChatGPT, eller et menneske — leser `prompt.txt`
og skriver svaret i `svar.json`:

```json
{
  "answer_version": "antidep/model-answer@1",
  "request_digest": "<står allerede i malen, kopieres uendret>",
  "identity": { "provider": "…", "model": "…", "model_version": "…" },
  "answered_at": "2026-09-10T09:12:00Z",
  "draft": { "extraction": {}, "field_groundings": [] }
}
```

`draft` er svaret som JSON-objekt. Kom svaret som ordrett tekst — med kodegjerder
eller annet støy — legges det i `completion` i stedet. Nøyaktig én av de to.

Identiteten er ikke pynt: verdiene registreres som premissene **utkastet** ble
laget under, og en plassholder som blir stående, ville vært en usann proveniens
(`docs/ANTIDEP_CONSTITUTION.md` §20). Kjøringen avviser derfor et svar der
identiteten fortsatt begynner på `SETT-INN-`.

Avtrykket binder svaret til nøyaktig den kildeteksten, den katalogen og den
promptmalen som ble spurt om. Endres én av dem, gjelder ikke et gammelt svar — og
det er riktig utfall, ikke et hinder.

## 7. Lag forslaget

```bash
npm run agent:draft-extraction -- --assignment assignments/fava-2000.json --close
```

Kjøringen skaffer representasjonen på nytt — fra adressen, eller ut av
originaldokumentet med den registrerte oppskriften — leser svaret, og skriver
`forslag.json` i kjøremappa **bare** hvis svaret holder mål:

1. formen er kontrakten i `proposals/extraction-proposal.schema.json`,
2. hver id står i oppdraget,
3. hvert `source_excerpt` og et eventuelt `source_quote` står **ordrett** i
   representasjonen.

Holder svaret ikke mål, skrives ingen fil. Kjøringen sier hvilket felt som var
galt, og skriver ut svaret avkortet, slik at det kan rettes i `svar.json` og
`--close` kjøres om igjen.

Begge kommandoene er idempotente, og tilstanden ligger i `kjoring.json`. En
kjøring som blir avbrutt, kan gjenopptas med den samme kommandoen.
`--status` sier hvor den står.

Hele arbeidsflyten, og hvordan den settes opp som en Routine, står i
[`../docs/ROUTINE_EXTRACTION.md`](../docs/ROUTINE_EXTRACTION.md).

## 8. Den eldre veien, som er beholdt

`npm run agent:propose-extraction` er den samme kjeden i én kommando, med et
**opptak** som inndata:

```bash
npm run agent:propose-extraction -- --assignment <fil> --prepare <katalog>
npm run agent:propose-extraction -- --assignment <fil> --recording <fil> --out <fil>
```

Den er beholdt fordi den er den korteste veien til å se prompten uten å kjøre en
modell, og til å spille av en kjøring om igjen. Den er ikke nødvendig i vanlig
drift: `--close` skriver selv et opptak ved siden av forslaget, med det samme
avtrykket.

## 9. Registrer forslaget

Forslaget er fortsatt bare en fil. Se `proposals/README.md`: det registreres av
`npm run agent:extract-evidence`, kontrolleres deterministisk av en **annen**
agentidentitet, og bekreftes deretter felt for felt av et menneske før noe kan
publiseres.

```bash
npm run agent:extract-evidence -- \
  --proposal assignments/fava-2000/forslag.json \
  --assignment assignments/fava-2000.json
```

**Oppdraget oppgis på nytt her, og det er ikke en gjentakelse.** Nøyaktig ett av
`--assignment`, `--model-proposal` og `--human-proposal` er påkrevd for hver
registrering, og valget er kallerens — ikke forslagets. Det avgjør både om
avgrensningen kontrolleres, og om raden føres som KI-assistert eller manuell. Forslaget har
vært innom en økt som leste utrygt eksternt innhold; oppdraget er redaktørens
egen fil og kommer en annen vei. Registreringen kontrollerer kildebindingen,
dokumentbindingen og hver katalogverdi mot oppdraget før den skriver noe — de
kontrollene den ordrette ikke kan gjøre, siden et utdrag kan stå ordrett i
kilden og likevel være ført på feil virkestoff eller lest ut av et annet
dokument.

Registreringen er en **egen** kommando, med sin egen legitimasjon, og skal kjøres
for seg. Modell-leddet nekter å kjøre dersom en agenthemmelighet står i miljøet:
et ledd som leser en artikkel Antidep ikke kontrollerer, skal ikke samtidig ha
tilgang til hemmeligheten som kan skrive en rad
(`docs/EVIDENCE_PIPELINE.md` §63).

Ingenting av det blir kortere av at modell-leddet finnes.

## Når en modelleverandør kobles på

Aktøren som svarer, er i dag en Claude Code Routine eller et menneske. Skulle
Antidep en dag kalle en leverandør direkte, føres adapteret opp som **én
oppføring** i `src/agents/model-adapters.ts`. Kontrakten, kjøringen, kontrollene
og databasen er uendret (`docs/ANTIDEP_CONSTITUTION.md` §20).

Svarfilen og opptaket faller da bort som nødvendige steg, men ikke som
muligheter: de er fortsatt måten å se prompten på, og å spille av en kjøring om
igjen, uten å bruke en modell.
