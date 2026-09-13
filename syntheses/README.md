# Syntesforslag

Her ligger **syntesforslagene**: én foreslått påstandsrevisjon per fil, med
evidensgrunnlaget den hviler på.

Evidensvurderingen hører **ikke** hjemme her. Den er et eget ledd med sin egen
rolle og sin egen legitimasjon, og den kommer etter claim-verifikasjonen; se
`assessments/README.md`.

Filene er **lokale arbeidsfiler**. De er gitignorerte og skal ikke commites: et
forslag er en påstand om hva Antidep mener evidensen viser, og den påstanden
skal ende som en rad i basen med proveniens — ikke som en fil i repoet.

## 1. Hvor forslaget kommer fra, og hvor det går

```text
registrert, menneskelig kildekontrollert evidens
  → modell-ledd (utenfor Antidep) leser grunnlaget og skriver denne filen
  → npm run agent:synthesise-claims   kontrollerer formen og registrerer
  → npm run agent:verify-claims       en SEPARAT kontroll, av en annen aktør
  → npm run agent:assess-evidence     evidensvurderingen, av enda en aktør
  → /review                           den faglige vurderingen, av et menneske
```

Registreringen gjør påstand, revisjon og evidenslenker i **én transaksjon**
(`api.register_claim_synthesis`, migrasjon 005am). Lenkene hører sammen med
revisjonen: evidensvurderingen forsegler evidenssettet, så en revisjon som fikk
lenkene sine i flere omganger, kunne blitt stående uten resten av grunnlaget
sitt.

Evidensvurderingen er derimot et eget ledd, og kommer etter kontrollen
(`MVP_IMPLEMENTATION_PLAN.md` §15, `EVIDENCE_PIPELINE.md` §61). En revisjon uten
vurdering er derfor en normal og synlig mellomtilstand; publiseringsgatens G10
stopper den til vurderingen finnes.

## 2. Hva skriveveien krever av evidensen

Hvert lenket evidensfunn må ha nådd kontrollnivået `EVIDENCE_PIPELINE.md` §26 og
§27 krever. Det er de samme vilkårene publiseringsgaten stiller, lest før
påstanden lages:

- en registrert ekstraksjonskontroll finnes, og **den gjeldende** konkluderer med
  `verified`
- kontrollene dekker til sammen alle feltene funnet påstår noe om
- kontrolløren hadde mandat
- ekstraksjonen er ikke trukket tilbake
- kilden er ikke `retracted` eller `withdrawn`

Svikter ett av dem, avvises forslaget med databasens egen setning om hvilket.
Det er tilsiktet: en påstand bygget på et funn som senere må rettes, må uansett
erstattes i sin helhet.

## 3. Formen

```json
{
  "proposal_version": "antidep/claim-synthesis-proposal@1",
  "generated_by": {
    "producer": "model",
    "provider": "…",
    "model": "…",
    "model_version": "…",
    "prompt_template_version": "…",
    "drafted_at": "2026-09-13T09:00:00Z",
    "request_digest": null
  },
  "claim": {
    "claim_id": null,
    "topic_concept_id": "…",
    "subject_drug_id": "…",
    "statement": "…",
    "scope": "…",
    "population_id": "…",
    "timeframe_min": "8 weeks",
    "timeframe_max": "8 weeks",
    "comparator_kind": "none",
    "comparator_drug_id": null,
    "direction": "increase",
    "magnitude_measure": null,
    "magnitude_value": null,
    "magnitude_unit": null,
    "qualifiers": "…",
    "uncertainty_summary": "…"
  },
  "evidence_links": [
    {
      "evidence_item_id": "…",
      "relationship_type": "supports",
      "directness": "indirect",
      "relevance_note": "…"
    }
  ]
}
```

Kjøringen skriver ut `evidence_set_digest` for hver registrerte revisjon. Det er
verdien vurderingsforslaget senere skal oppgi (`assessments/README.md`).

`claim_id` er `null` for en ny påstand, og id-en til en eksisterende påstand når
forslaget er en **ny revisjon** av den. Revisjonsnummeret og hva revisjonen
erstatter, settes av databasen.

## 4. Hva filen ikke får bestemme

| Felt                                        | Hvorfor ikke                                                                                                                                                                             |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `knowledge_type`                            | Skriveveien registrerer `evidence_synthesis` og ingenting annet. Et deterministisk faktum avgjøres mot en autoritativ kilde; en klinisk anbefaling skal ikke ha en KI-kjøring som opphav |
| `created_by_actor_id`                       | Aktøren er kjøringens egen, hentet av databasen fra legitimasjonen                                                                                                                       |
| `revision_number`, `supersedes_revision_id` | Databasen teller selv, slik at historikken ikke kan få et hull eller en sirkel                                                                                                           |
| `assessment`                                | Evidensvurderingen er et eget ledd med sin egen rolle og sin egen legitimasjon, og registreres etter claim-verifikasjonen (`assessments/README.md`)                                      |

Et ukjent felt avvises framfor å bli ignorert: en skrivefeil i et feltnavn ville
ellers blitt til en manglende verdi i en klinisk påstand.

## 5. Kjøringen er ikke idempotent, og kan ikke være det

Kjør den samme filen to ganger uten `claim_id`, og du får **to påstander** med
hver sin revisjon.

Det er ikke en forglemmelse. `knowledge.claim_revisions.content_hash` er bevisst
_ikke_ unik (migrasjon 004): evidensgrunnlaget er en del av revisjonens betydning
og inngår ikke i hashen, så «samme ordlyd, nytt evidenssett» er en helt legitim
ny revisjon. En sperre på hashen ville stengt nettopp den korreksjonsveien —
samme blindvei som en for smal hash skapte på evidensfunnene, ett nivå opp.

Ansvaret ligger derfor hos den som kjører: kontroller i `/review` at påstanden
ikke allerede finnes før du registrerer den, og oppgi `claim_id` når forslaget er
en **ny revisjon** av en påstand som står der fra før. Kjøringen skriver ut
påstands-ID-en og revisjonsnummeret den registrerte, slik at det er lesbart hva
som faktisk skjedde.

Av samme grunn skiller kjøringen mellom en **avvisning av forslaget** og alt
annet. Et forslag føres som avvist bare når databasen sier nei med en kjent,
forslagsspesifikk SQLSTATE — et vilkår som ikke holder, en verdi kolonnen ikke
tar imot. Da er transaksjonen rullet tilbake, ingenting er skrevet, og det var
forslaget det var noe i veien med.

En vranglås, en serialiseringsfeil, en manglende rettighet eller en intern
databasefeil ruller også transaksjonen tilbake, men sier ingenting om forslaget
og gjentar seg gjerne for det neste; de velter kjøringen. Det samme gjør et
uavklart utfall — en forbindelse som ryker, eller et svar som ikke har formen
kontrakten lover: raden kan finnes, og en ny kjøring ville laget påstanden en
gang til. Kjøringen lukkes da som `failed`. Kontroller `/review` før du kjører om
igjen.

## 6. Språk og presisjon

`statement`, `scope`, `qualifiers` og `uncertainty_summary` er klinikerens tekst
og skal være på norsk bokmål, nøkternt og uten å være mer presise enn
evidensen tillater (`ANTIDEP_CONSTITUTION.md` §3, §4, §6,
`EVIDENCE_PIPELINE.md` §29, §30).

`magnitude_value` skal stå tomt med mindre grunnlaget faktisk forsvarer en
tallfesting. Tallene fra kildene ligger uansett på evidensfunnene, og en påstand
som er mer presis enn evidensen under den, er et brudd på §4 og §6.
