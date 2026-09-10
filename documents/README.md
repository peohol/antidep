# Originaldokumenter

Her ligger **originaldokumentene** — i praksis PDF-ene av fulltekstartiklene —
som Antideps kildeversjoner er utledet av.

Filene er **lokale arbeidsfiler**. De er gitignorerte, deployes ikke, og skal
aldri commites: en forskningsartikkel er opphavsrettslig beskyttet, og Antidep
har ikke rett til å redistribuere fullteksten
(`docs/EVIDENCE_PIPELINE.md` §14).

## 1. Hva Antidep lagrer, og hva den ikke lagrer

Databasen lagrer **ikke** dokumentet. Den lagrer:

| Opplysning            | Hva den er                                                    |
| --------------------- | ------------------------------------------------------------- |
| `document_sha256`     | sha256 av dokumentets byte, beregnet av databasen selv        |
| `document_byte_size`  | antall byte                                                   |
| `document_media_type` | avlest av dokumentets egen signatur, i dag `application/pdf`  |
| `text_extraction_*`   | verktøyet, versjonen og argumentene teksten ble hentet ut med |
| `content_hash`        | sha256 av **teksten** oppskriften ga                          |

Det er nok til at hvem som helst med sin egen lovlige kopi kan etterprøve alt:

```bash
sha256sum artikkel.pdf                       # skal gi document_sha256
pdftotext -layout -enc UTF-8 -eol unix artikkel.pdf - | sha256sum
                                             # skal gi content_hash
```

Stemmer begge, er teksten ekstraksjonen ble lest av, nøyaktig den som er
registrert.

## 2. Filnavnet er fingeravtrykket

Kjeden slår opp et dokument på **fingeravtrykket**, ikke på filnavnet:
katalogen leses, hver fil hashes, og den som stemmer er dokumentet. Filene kan
derfor hete hva som helst, men `npm run editor:assignment` legger dem inn som
`<sha256 uten prefiks>.pdf`.

Det er ikke pynt. «Fava-2000.pdf» er ikke en identitet: to filer med samme navn
kan være to forskjellige dokumenter, og en fil som er byttet ut, ville aldri
blitt oppdaget. Fingeravtrykket er det samme overalt og endrer seg av ett
eneste tegn.

## 3. Hvilke ledd trenger katalogen

Alle leddene som skal se **teksten** til en dokumentutledet kildeversjon:

```bash
npm run editor:assignment    -- … --pdf <fil>          # legger filen inn her
npm run agent:draft-extraction -- --assignment <fil> --open
npm run agent:extract-evidence -- --proposal <fil> --assignment <fil>
npm run agent:verify-extraction
```

De tre siste finner katalogen av `ANTIDEP_DOCUMENT_DIR`, eller av `--documents
<katalog>`. Standardverdien er denne katalogen.

Finner et ledd ikke dokumentet, **stopper det**. Det henter aldri
`retrieved_from` i stedet: da ville kontrollen hvilt på noe annet enn det
ekstraksjonen ble lest av, og det er nøyaktig den forvekslingen hele
dokumentveien finnes for å hindre.

## 4. Verktøyet

Tekstuttrekkingen bruker `pdftotext` fra poppler:

```bash
apt-get install poppler-utils   # Debian/Ubuntu
brew install poppler            # macOS
```

Versjonen registreres sammen med oppskriften. En annen versjon som gir nøyaktig
den samme teksten, er like god — fasiten er fingeravtrykket, ikke versjonsnummeret.
Gir den en annen tekst, sier kjeden fra og navngir begge versjonene.
