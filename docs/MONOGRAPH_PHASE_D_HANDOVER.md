# Overlevering til fase D — pilotmonografien for sertralin

Fase C er levert: flyten fra «bygg monografi for sertralin» til et kontrollert,
delvis utkast med ærlig dekning går gjennom de autoriserte inngangene ende til
ende. Fase D er noe annet — å prøve arbeidsformen **faglig** på én reell
monografi, og se hvor den holder og hvor den ikke gjør det.

Dette dokumentet er kort med vilje. Det sier hvordan piloten startes, hvem som
gjør hva, hvor man ser etter, og hva som faktisk står i veien. Spesifikasjonene
ligger i [MONOGRAPH_STANDARD.md](MONOGRAPH_STANDARD.md) og
[SOURCE_POLICY.md](SOURCE_POLICY.md), og gjentas ikke her.

## 1. Hvordan en sertralinbestilling startes

Uten en artikkelliste. Det er hele poenget.

En kliniker med redaktørmandat åpner `/monografi`, velger sertralin, og trykker
**«Bygg monografi for sertralin»**. Antidep oppretter kunnskapsbehovene av
standarden i det samme kallet, legger søkeplanene i køen, og begynner å lete
etter kilder selv. Ingen DOI, ingen tittel og ingen kildeliste er en
forutsetning.

Manuell artikkelregistrering finnes fortsatt — `/be-om-artikkel` — men den er et
supplement. Den er ikke normalinngangen, og piloten skal ikke bruke den som det.

For en driftskjøring uten flate er inngangen `api.order_monograph(p_drug_name,
p_note)` med redaktørmandat.

## 2. Hvordan ChatGPT og de andre agentrollene arbeider i flyten

Seks semantiske ledd har hver sin tildelte KI-tjeneste, og ingen to ledd kan
dele en modell (`provenance.role_model_assignments`, eksklusjonsbegrensning):

| Ledd                        | Hva det avgjør                                        |
| --------------------------- | ----------------------------------------------------- |
| `source_discovery`          | Planlegger søket og foreslår kilder og utvidelser.    |
| `source_quality_assessment` | Kontrollerer søkedekningen — med **egne** motsøk.     |
| `evidence_extraction`       | Henter opplysningene ut av fullteksten.               |
| `claim_synthesis`           | Formulerer påstanden for ett kunnskapsbehov.          |
| `evidence_assessment`       | Graderer grunnlaget.                                  |
| `monograph_answer`          | Skriver det strukturerte svaret for behovet.          |

To ledd er Antideps egen deterministiske kode og kan **ikke** settes ut til en
modell: `search-execution-and-registration` (som faktisk utfører søkene) og
svarkontrollen. Det er derfor et søk Antidep utførte selv, bærer et responsavtrykk,
mens et søk en agent *rapporterer*, er lagret som agentens egen beretning — de to
blandes ikke.

ChatGPT henter arbeid gjennom den private MCP-appen
([CHATGPT_WORKSPACE_AGENT.md](CHATGPT_WORKSPACE_AGENT.md)): fem verktøy, ingen
SQL, ingen generell databasevei. Ingen ny modellnøkkel og ingen betalt modell-API
er innført i fase C. Nedlast/opplast-veien (`npm run ops:agents -- export-task` /
`import-answer`) består som teknisk recovery.

**ChatGPT kan lede piloten uten å godkjenne sitt eget arbeid.** Det er ikke en
høflighetsregel, det er en databasegrense: den separate dekningskontrollen kan
ikke tildeles den samme modellen som kildeoppdagelsen, sluttkontrollen krever et
navngitt menneske med reviewer-mandat, og publiseringen krever et *annet*
menneske med publisher-mandat. Ingen agent kan attestere at et menneske har
vurdert innhold.

De to driftskommandoene som faktisk utfører søk og innhenting:

```
npm run ops:discovery      # kjører søkene mot Europe PMC, PubMed og Crossref
npm run ops:acquire        # henter originalmateriale der det er åpent tilgjengelig
```

Begge leser legitimasjonen sin fra miljøet, og begge registrerer gjennom de
kontrollerte skriveveiene. `ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke` viser
at de virker mot de ekte tjenestene.

## 3. Hvor piloten inspiseres

| Hva                                  | Hvor                                              |
| ------------------------------------ | ------------------------------------------------- |
| Bestillingene og hvor langt de er    | `/monografi`                                      |
| Dekning, utkast, avvik, forespørsler | `/monografi/<håndtak>`                            |
| Hva Antidep arbeider med nå          | `/arbeid` (åpen, uten innlogging)                 |
| Artikler Antidep mangler             | `/fulltekst`                                      |
| Påstander som har fått ny forskning  | `/ny-evidens`                                     |
| Tekniske problemer                   | `/tekniske-problemer` (admin)                     |
| Hele søkeloggen per plan             | `api.monograph_search_plans(<utgave>)`            |
| Åpne avvik                           | `api.monograph_revision_proposals(<utgave>)`      |
| Utestående originalmateriale         | `api.monograph_source_requests(<utgave>)`         |

Tre redaktørveier finnes for overlapp mellom kilder, og de brukes når piloten
oppdager at to publikasjoner handler om det samme deltakerutvalget:
`api.register_study_report(<referanse>, …)` sier at en artikkel er en rapport om
en studie, `api.link_review_included_study(<oversikt>, …)` sier at en
systematisk oversikt inkluderer en bestemt studie, og
`api.retract_review_included_study(<oversikt>, …)` trekker tilbake en
inklusjonskobling som viste seg å være feil. Alle navngir kilden med en DOI, et
PubMed-nummer, et forsøksregisternummer eller en entydig tittel — aldri med en
intern id. Registreres eller trekkes et overlapp tilbake mens en synteseoppgave
eller evidensvurdering står ute, blir den oppgaven foreldet og må hentes ut på
nytt; det er tilsiktet, og det er nettopp det som hindrer at et svar bygget på
en dobbelttelt tilstand kommer inn i ettertid.

Utgaven har seks atskilte dimensjoner, og de slås aldri sammen: relevans,
arbeidstilstand, faglig utfall, evidenssikkerhet, aktualitet og kontrollstatus.
«Venter på tilgang», «venter på en avklaring» og «teknisk stopp» er
arbeidstilstander — de er **ikke** «utilstrekkelig evidens» eller «ingen
relevante studier», og flaten sier det med ord.

## 4. Hvordan pilotens feil og arbeidsmengde vurderes

Fire steder svarer på det uten at noen må lese en logg:

1. **Dekningen** på `/monografi/<håndtak>` viser seks tall hver for seg. Et
   spørsmål som er fjernet fra nevneren, ville vært skjult; det kan det ikke
   bli — nevneren er den lagrede behovslisten for utgaven.
2. **«Dette står i veien»** lister hva som mangler, med antall. Det er den
   direkte målingen av hvor mye menneskelig arbeid som faktisk kreves.
3. **Avvikslisten** viser hvor automatikken og et låst svar er uenige, og hvor
   en relevant kilde står utenfor en forhåndsgodkjent liste. Hvert avvik bærer
   sin egen begrunnelse.
4. **Forespørselslisten** viser artiklene Antidep ikke fikk tilgang til, med den
   faglige grunnen. En betalingsmur står som en tilgangsbegrensning.

Når piloten finner en feil, er den riktige responsen å rette den — ikke å skrive
en ny spesifikasjon.

## 5. Reelle oppsett- og tilgangsbegrensninger

Disse er faktiske, og de er ikke klinikeroppgaver:

- **Modelltildeling.** De seks semantiske leddene må ha en tildelt tjeneste før
  databasen legger ut arbeid til dem. Gjøres med `npm run ops:agents`, eller av
  en redaktør gjennom `api.assign_agent_role_model`. Uten tildeling stopper
  flyten med en tydelig avvisning framfor å gjette.
- **Agentlegitimasjon.** Hvert kontrolledd har en egen identitet som er *inert*
  til legitimasjonen utstedes i det miljøet kjøreren leser hemmeligheten fra
  (`scripts/issue-agent-credential.sh`).
- **Utgiverens botvern.** Flere utgivere svarer 403 på en automatisk henting,
  også av åpen fulltekst. Det er en tilgangsbegrensning, ikke en faglig
  utelukkelse, og ikke en feil i koden. I praksis betyr det at en del
  forskningsfulltekst må lastes opp av et menneske gjennom `/fulltekst`.
  Forespørselen viser artikkelidentiteten og den faglige grunnen, samlet, slik
  at det ikke blir et klikk per artikkel.
- **Søkebredden.** De maskinelle søkene er bevisst bredere enn analysen
  ([SOURCE_POLICY.md](SOURCE_POLICY.md) §4.1), og treffene inneholder derfor
  mye som ikke er relevant. Å skille dem er kildeoppdagelsens faglige arbeid,
  ikke søkeutførelsens. Piloten bør se på om utvalget faktisk blir godt nok.
- **Studieidentitet må fylles for eldre kilder.** Kildeoppdagelsen registrerer
  koblingen av seg selv når treffet kom på et forsøksregisternummer, men et
  treff funnet på DOI bærer den ikke. Ser piloten to publikasjoner som kan være
  rapporter om den samme studien, registreres det med `api.register_study_report`
  — med grunnlaget skrevet ut, og som `usikker` når det er usikkert.
  Synteseoppgaven viser da at grunnlaget hviler på færre uavhengige studier enn
  antall funn.
- **Norske produktopplysninger.** Preparatomtaler registreres gjennom
  myndighetsveien (HTML, XML eller JSON med sin egen integritetskontroll).
  PDF avvises der med vilje: forskningsfulltekstens PDF-vei har sin egen
  kontroll, og de to skal ikke blandes.
- **Ingen hostet endring.** Alt arbeidet i fase C er gjort mot en lokal,
  isolert database. Ingen produksjonspublisering og ingen hostet
  databaseendring inngår.

## 6. Hva som ikke er gjort, og ikke skal gjøres i fase D

- Den komplette sertralinmonografien er **ikke** gjennomført faglig.
- Produksjonen er **ikke** fylt med kliniske prøvesvar.
- Ingen faglig godkjenning og ingen menneskelig publisering er simulert.
- Nedtrappings-/byttekalkulator, full sammenlikningsfunksjon og utrulling til
  alle antidepressiver er ikke bygget. Datamodellen bærer dem fortsatt: en
  rettet relasjon er rettet (A→B er ikke B→A), og byttepar gjentas per retning.

## 7. Prøvene som viser at flyten virker

```
npm run db:test                       # 79 filer, 2993 databaseprøver
npm run db:test:monograph             # hele forløpet, fersk base
npm run db:test:monograph:upgrade     # samme forløp oppå en base med innhold
npm run test                          # flatene og modulene
npm run verify:repo                   # repokontrollene
ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke   # ekte søk, ekte innhenting
```

Den siste går ut på det åpne nettet og må bes om. Den er en teknisk røyktest og
ingen faglig prøve.
