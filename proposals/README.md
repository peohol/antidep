# Ekstraksjonsforslag

Her legger du JSON-filene som beskriver hva én artikkel sier om ett evidensfunn.
Ett forslag = én artikkel = ett funn.

Filene er **lokal inndata**. De er gitignorert, deployes ikke, og er ikke faglig
innhold: det faglige innholdet blir til når forslaget er registrert i basen med
proveniens. Bare kontrakten (`extraction-proposal.schema.json`) og eksempelet
(`eksempel-syntetisk-forslag.json`) er commitet.

Forslaget skriver ingenting selv. Den som lager det — modell-leddet
(`assignments/README.md`), ChatGPT utenfor Antidep, eller et menneske — har
ingen tilgang til databasen. Alt som skrives, skjer i kjøringen etterpå, med
agentlegitimasjon og under de deterministiske kontrollene.

## 1. Finn riktig kildeversjon

Et forslag er bundet til nøyaktig **én kildeversjon**: ett hentet øyeblikksbilde
av kilden, med sin egen adresse og sitt eget fingeravtrykk. Uten den kan
utdragene ikke etterprøves.

Er kilden og versjonen registrert fra før, finner du de tre verdiene i
`api.editor_source_versions` (krever `editor`-rolle):

```sql
select sv.source_version_id, sv.retrieved_from, sv.content_hash
from api.editor_source_versions sv
join api.editor_sources s on s.source_id = sv.source_id
where s.title ilike '%Fava%';
```

Er den ikke registrert, registrer den først i adminflyten («Ny kildeversjon» på
kildesiden). Da får du `source_version_id`, `retrieved_from` og `content_hash`
derfra.

De tre verdiene, sammen med `source_id`, er de eneste feltene i forslaget som
**ikke** leses ut av artikkelen. Alt annet skal komme fra teksten.

## 2. Hvilken representasjon gjelder utdragene?

Kildeversjonen sier selv hva slags representasjon som ble hentet: fulltekst,
abstrakt, registerdata, et regulatorisk sammendrag eller en sekundær omtale.
**Utdragene i forslaget må stå ordrett i nettopp den representasjonen** —
kjøringen henter adressen på nytt og søker i det den får.

Det betyr i praksis: er kildeversjonen registrert som et abstrakt fra PubMed,
kan et forslag laget av fulltekst-PDF-en ikke registreres, fordi setningene ikke
står i abstraktet. Da må fulltekstens egen kildeversjon registreres først.

## 3. Slik ser et forslag ut

Se `eksempel-syntetisk-forslag.json` for en fullstendig, realistisk fil, og
`extraction-proposal.schema.json` for den maskinlesbare kontrakten. Skjemaet kan
skrives ut på nytt med:

```bash
npm run agent:extract-evidence -- --schema
```

Kort fortalt har filen fire deler:

- **`generated_by`** — hvem som leste kilden og foreslo verdiene,
- **hvilken kildeversjon** som ble lest (`source_id`, `source_version_id`,
  `retrieved_from`, `content_hash`),
- **`extraction`** — de strukturerte verdiene, hver med sin `*_availability` som
  sier hvorfor en verdi eventuelt mangler,
- **`field_groundings`** — én per semantisk felt, med det ordrette utdraget,
  den presise pekeren og en kort begrunnelse.

Tre regler er verdt å ta med til den som skriver forslaget:

1. Et **ukjent felt er en feil**, ikke noe som ignoreres. Skrivefeil i et
   feltnavn stopper kjøringen framfor å bli en manglende verdi.
2. **Ingenting fylles inn.** Mangler kilden en verdi, sier `*_availability` det.
   Manglende forankring gjettes aldri fram.
3. **Utdraget må stå ordrett i kilden**, med nok kontekst til å være
   kontrollgrunnlag — minst hele setningen verdien står i.

### `generated_by`: hvem som laget forslaget

Feltet er påkrevd, og det er ikke en opplysning ved siden av — det avgjør to
ting. Leverandøren, modellen, modellversjonen og promptmalversjonen registreres
som **premissene** for agentkjøringen som skriver raden. Og `producer` avgjør om
funnet føres som et KI-assistert forslag eller som en menneskelig ekstraksjon.

Et forslag fra modell-leddet får blokken fylt ut automatisk. Skriver du
forslaget selv, ut av en lovlig innhentet fulltekst, er dette blokken:

```json
"generated_by": {
  "producer": "human",
  "provider": "human",
  "model": "manuell-ekstraksjon",
  "model_version": "not_applicable",
  "prompt_template_version": "not_applicable"
}
```

Laget ChatGPT utkastet utenfor Antidep, er `producer` `model`, og `provider`,
`model` og `model_version` skal si hvilken modell det faktisk var.

Verdien inngår i evidensfunnets fingeravtrykk. De samme strukturerte verdiene
erklært av et menneske og av en modell er derfor **to rader**, ikke én rad som
skifter mening.

## 4. Tørrkjøring

```bash
npm run agent:extract-evidence -- --proposal proposals/fava-2000.json --dry-run
```

Henter kildeversjonen, krever at fingeravtrykket stemmer, og prøver hvert utdrag
ordrett mot representasjonen. **Skriver ingen evidensrad.** Kjøringen registreres
likevel i `provenance.agent_runs` og lukkes som `aborted`, slik at også en
tørrkjøring er sporbar.

Feiler den, sier den hvilket felt som ikke lot seg finne. Rett forslaget og kjør
igjen.

## 5. Registrering

```bash
npm run agent:extract-evidence -- --proposal proposals/fava-2000.json
```

Samme kontroller, og deretter registrering gjennom
`api.register_agent_extraction(...)`. Databasen avviser ekstraksjonen dersom
forankringen ikke dekker hvert semantiske felt raden påstår noe om.

Kjøringen er idempotent: den samme filen kjørt om igjen skriver ingenting.
Fingeravtrykket databasen sammenligner mot, dekker både de strukturerte verdiene
og kildeforankringen. Rekkefølgen på forankringene i filen er ikke en del av det:
de samme forankringene i en annen rekkefølge er fortsatt det samme funnet.

**En rettet forankring blir et nytt funn.** Retter du bare et `source_excerpt`,
en `source_locator` eller en `justification`, og lar hver strukturerte verdi stå,
registreres det som et **nytt** evidensfunn ved siden av det gamle. Det gamle
består urørt — det er append-only, og en ekstraksjon som ble laget av et annet
utdrag, er en annen ekstraksjon.

Det nye funnet arver ingenting: verken maskinkontrollen, den menneskelige
ekstraksjonskontrollen, koblingen til en påstand eller en publiseringsgodkjenning.
Kjøringen kjører den deterministiske kontrollen på det med det samme; resten er
faglig arbeid i adminflyten.

## 6. Den deterministiske kontrollen etterpå

```bash
npm run agent:verify-extraction -- --evidence-item <uuid>
```

En **separat** operasjon, av en annen agentidentitet, som henter kildeversjonen
på nytt og beviser at hvert forankret utdrag står ordrett i den. Uten den kan
ingen kliniker bekrefte funnet felt for felt i kontrolløkten.

## Å lage forslaget med modell-leddet

```bash
npm run agent:propose-extraction -- --assignment <oppdrag> --prepare <katalog>
npm run agent:propose-extraction -- --assignment <oppdrag> --recording <opptak> --out <fil>
```

Leddet leser kildeversjonen og skriver et forslag her. Det har ingen
databasetilgang, og skriver aldri en rad. Hele oppskriften står i
`assignments/README.md`.

## Flere artikler på én gang

```bash
npm run agent:reextract-evidence -- --directory proposals --dry-run
npm run agent:reextract-evidence -- --directory proposals
```

Kjører alle `.json`-forslagene i katalogen i navnerekkefølge, og kjører den
deterministiske kontrollen på hvert nytt funn med det samme. Dette er veien for
å re-ekstrahere de gamle evidensfunnene: det nye, forankrede funnet kommer **ved
siden av** det gamle, og det gamle røres ikke.

Ble en tidligere kjøring avbrutt mellom registreringen og kontrollen, fullfører
den neste kjøringen kontrollen framfor å skrive en ny rad. Databasen navngir da
raden forslaget kolliderte med, etter det samme fingeravtrykket som avviste
dubletten, og kontrollen gjøres på nøyaktig den raden. Resten av arbeidskøen
står urørt.

Kommandoen avslutter med feil dersom noe funn står uten registrert maskinbevis.
Da er kjeden ikke komplett, og kontrolløkten i UI-et vil stoppe på funnet.

Å lenke et nytt funn til en påstand er en faglig vurdering og gjøres av en
kvalifisert redaktør i adminflyten — ikke av en kommando.
