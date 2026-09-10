# Oppdrag til modell-leddet

Et **oppdrag** er det modell-leddet får vite som ikke står i artikkelen:
hvilken kildeversjon det skal lese, og hvilke virkestoff, endepunkt og
populasjoner funnet kan peke på.

Modell-leddet leser oppdraget og kilden, og skriver ett **ekstraksjonsforslag**
(`proposals/`). Det er alt det gjør. Det har ingen databasetilgang, ingen
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

## 4. Skriv ut prompten og et tomt opptak

```bash
npm run agent:propose-extraction -- \
  --assignment assignments/fava-2000.json \
  --prepare assignments/fava-2000
```

Kommandoen henter kildeversjonen, krever at fingeravtrykket stemmer, og skriver
to filer:

- `prompt.txt` — nøyaktig det modellen skal få se,
- `opptak.json` — et tomt opptak som allerede bærer riktig fingeravtrykk av
  forespørselen.

Den skriver ingenting i databasen.

## 5. Kjør prompten, og lim inn svaret

Kjør `prompt.txt` der modellen faktisk kjører — i dag utenfor Antidep, for
eksempel i ChatGPT. Lim svaret inn i `completion` i `opptak.json`, og fyll ut
`identity` med leverandøren, modellen og modellversjonen som **faktisk** svarte.

Identiteten er ikke pynt: verdiene havner i `provenance.agent_runs` som
premissene kjøringen ble gjort under, og en plassholder som blir stående, er en
usann proveniens (`docs/ANTIDEP_CONSTITUTION.md` §20).

Opptaket er nøklet på fingeravtrykket av forespørselen. Endres kildeteksten,
katalogen i oppdraget eller promptmalen, gjelder ikke et gammelt svar — og det
er riktig utfall, ikke et hinder.

## 6. Lag forslaget

```bash
npm run agent:propose-extraction -- \
  --assignment assignments/fava-2000.json \
  --recording assignments/fava-2000/opptak.json \
  --out proposals/fava-2000.json
```

Kjøringen henter kildeversjonen på nytt, krever at fingeravtrykket er den
registrerte, spør modelladapteret, og skriver et forslag **bare** hvis svaret
holder mål:

1. formen er kontrakten i `proposals/extraction-proposal.schema.json`,
2. hver id står i oppdraget,
3. hvert `source_excerpt` og et eventuelt `source_quote` står **ordrett** i
   representasjonen.

Holder svaret ikke mål, skrives ingen fil. Kjøringen sier hvilket felt som var
galt, og skriver ut modellens svar avkortet, slik at opptaket kan rettes.

## 7. Registrer forslaget

Forslaget er fortsatt bare en fil. Se `proposals/README.md`: det registreres av
`npm run agent:extract-evidence`, kontrolleres deterministisk av en **annen**
agentidentitet, og bekreftes deretter felt for felt av et menneske før noe kan
publiseres.

Ingenting av det blir kortere av at modell-leddet finnes.

## Når en modelleverandør kobles på

`--prepare` og opptaket er arbeidsformen så lenge `recorded` er det eneste
adapteret. Et leverandøradapter føres opp som **én oppføring** i
`src/agents/model-adapters.ts`, og velges med `--model <navn>`. Kontrakten,
kjøringen, kontrollene og databasen er uendret
(`docs/ANTIDEP_CONSTITUTION.md` §20).

`--prepare` faller da bort som nødvendig steg, men ikke som mulighet: det er
fortsatt måten å se prompten på uten å bruke en modell.
