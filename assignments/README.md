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

## 1. Hvorfor katalogen står i filen

Modell-leddet kan ikke slå opp i databasen. Det leser utrygt eksternt innhold,
og et ledd som gjør det, skal ikke samtidig ha en leseflate inn i Antidep.

Det er heller ikke bare en teknisk grense. Hvilket virkestoff og hvilket
endepunkt et evidensfunn gjelder, er en **faglig avgrensning**. En modell som
fikk velge fritt i hele katalogen, kunne flyttet funnet til et naboendepunkt
uten at noe merket det: utdragene ville fortsatt stått ordrett i kilden, og den
deterministiske kontrollen kontrollerer utdrag — ikke avgrensning.

Listen er derfor redaktørens, og modellen velger innenfor den. En id som ikke
står i oppdraget, avvises av kjøringen.

## 2. Hvor verdiene står

Alle sju verdiene finnes i adminflyten, som krever `editor`-rolle:

```sql
-- kildeversjonen: source_id, source_version_id, retrieved_from, content_hash
select sv.source_id, sv.source_version_id, sv.retrieved_from, sv.content_hash
from api.editor_source_versions sv
join api.editor_sources s on s.source_id = sv.source_id
where s.title ilike '%Fava%';

select drug_id, canonical_name from api.editor_drugs;
select outcome_concept_id, canonical_label from api.editor_outcomes;
select population_id, canonical_label from api.editor_populations;
```

Er kildeversjonen ikke registrert, registrer den først («Ny kildeversjon» på
kildesiden).

## 3. Slik ser et oppdrag ut

Se `eksempel-syntetisk-oppdrag.json`. Kort fortalt:

- **hvilken kildeversjon** som skal leses (`source_id`, `source_version_id`,
  `retrieved_from`, `content_hash`),
- **`drugs`** og **`outcomes`** — minst ett av hver, med id og navn,
- **`populations`** — kan være tom. Passer ingen registrert populasjon, sier
  forslaget det i `population_availability` framfor å velge en som nesten
  passer.

Navnene ved siden av id-ene er for modellens skyld. Det er id-en som registreres.

Et ukjent felt er en feil, ikke noe som ignoreres.

## 4. Kjør modell-leddet

Dette er den vanlige veien, og den en Claude Code Routine kjører: to kommandoer
med en fil imellom.

```bash
npm run agent:draft-extraction -- --assignment assignments/fava-2000.json --open
```

Kommandoen henter kildeversjonen, krever at fingeravtrykket stemmer, og legger
igjen en **kjøremappe** — `assignments/fava-2000/`, utledet av oppdragsfilen:

| Fil            | Hva den er                                                                    |
| -------------- | ----------------------------------------------------------------------------- |
| `kjoring.json` | Tilstanden: kildeversjonen, forespørselens fingeravtrykk, hvor kjøringen står |
| `prompt.txt`   | Nøyaktig det modellen skal få se                                              |
| `svar.json`    | Malen aktøren som utfører modellarbeidet, fyller ut                           |

Den skriver ingenting i databasen.

## 5. Legg inn svaret

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

## 6. Lag forslaget

```bash
npm run agent:draft-extraction -- --assignment assignments/fava-2000.json --close
```

Kjøringen henter kildeversjonen på nytt, krever at fingeravtrykket er den
registrerte, leser svaret, og skriver `forslag.json` i kjøremappa **bare** hvis
svaret holder mål:

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

## 7. Den eldre veien, som er beholdt

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

## 8. Registrer forslaget

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
`--assignment` og `--no-assignment-check` er påkrevd for hver registrering, og
valget er kallerens — ikke forslagets. Forslaget har
vært innom en økt som leste utrygt eksternt innhold; oppdraget er redaktørens
egen fil og kommer en annen vei. Registreringen kontrollerer kildebindingen og
hver katalogverdi mot oppdraget før den skriver noe — den ene kontrollen den
ordrette ikke kan gjøre, siden et utdrag kan stå ordrett i kilden og likevel være
ført på feil virkestoff.

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
