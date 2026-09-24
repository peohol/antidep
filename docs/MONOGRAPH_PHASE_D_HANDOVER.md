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

Seks semantiske ledd har hver sin tildelte KI-tjeneste
(`provenance.role_model_assignments`). Flere ledd kan bruke den samme modellen:
den utfører dem som atskilte kjøringer, hver under sin egen rolle og sin egen
instruks. Det som ikke kan deles, er kjøringen — et svar kan ikke attestere sitt
eget resultat — og registreringsleddet, som er Antideps egen kode per ledd
(migrasjon 013t):

| Ledd                        | Hva det avgjør                                        |
| --------------------------- | ----------------------------------------------------- |
| `source_discovery`          | Vurderer de maskinelt utførte søkene, velger kilder, og ber om flere søk. |
| `source_quality_assessment` | Kontrollerer søkedekningen på sine **egne**, separat utførte motsøk. |
| `evidence_extraction`       | Henter opplysningene ut av fullteksten.               |
| `claim_synthesis`           | Formulerer påstanden for ett kunnskapsbehov.          |
| `evidence_assessment`       | Graderer grunnlaget.                                  |
| `monograph_answer`          | Skriver det strukturerte svaret for behovet.          |

To ledd er Antideps egen deterministiske kode og kan **ikke** settes ut til en
modell: `search-execution-and-registration` (som faktisk utfører søkene) og
svarkontrollen. Et søk Antidep utførte selv, bærer endepunktet og et
responsavtrykk; en agents beretning om et verktøykall gjør det ikke, og de to
blandes ikke.

Hvert obligatorisk søkespor har en maskinell søkemetode (migrasjon 014c). Hva
hver metode kan dekke, og for hvilke profiler, er registrert i
`knowledge.monograph_search_methods` og `knowledge.monograph_search_platforms`,
og et søk må si hvilken metode det brukte og kan ikke erklære et spor metoden
ikke står oppført for. Metodene er fritekstsøkene i Europe PMC, PubMed og
Crossref, PubMeds og Europe PMCs filtre for oversikter, observasjonsstudier,
humane primærstudier, veiledninger og oppdateringer, ClinicalTrials.gov for
forsøksregistrene, FEST fra Direktoratet for medisinske produkter for REG- og
PROD-sporene og preparatomtalene, EMAs publiserte sikkerhetsvurderinger for
sikkerhetsprofilene, ClinPGx for farmakogenetikken, og Europe PMC og Crossref for
referanselistene og de siterende arbeidene til kildene kildeoppdagelsen velger
ut. Tabellen i [SOURCE_POLICY.md](SOURCE_POLICY.md) §4.2 sier hva hver av dem
*ikke* dekker. Sammendragsleddet (SYN) søker ikke og får ingen søkeplan.

Redaktørens vei, `api.record_monograph_track_by_editor(...)`, finnes fortsatt,
men som en kontrollert reservevei for reelle unntak og ikke som arbeidsflyten:
den brukes bare når et spor står som `no_machine_path`, og det skjer bare når
registeret mangler veien. Passeringen blir en egen rad i søkeloggen med
`editor_recorded` som utførelsesbevis, og sporet knyttes til nøyaktig den raden.
Ingen av leddene kan gjøre den andres arbeid, og ingen av dem kan late som
(migrasjon 013x, 014c).

**Ingen av de seks leddene utfører nettverkskall, og ingen av dem kan.** Den
autonome kjøreren har Antidep-appens fem verktøy og ikke ett til, og ingen av
dem søker. Fram til migrasjon 013v ba `source_discovery`-oppgaven likevel om
faktiske databasesøk — en motsigelse som ble prøvd i drift, der agenten
frigjorde oppgaven med `could_not_complete` framfor å dikte opp søk. Den er
rettet ved å gjøre arbeidsdelingen til én ting:

1. `npm run ops:discovery` utfører søkerundene planen åpnet — én per
   søkemetode planen trenger — og registrerer hvert søk med metode, endepunkt,
   søkestreng, treffantall og responsavtrykk.
2. Først da finnes den semantiske oppgaven. Porten er
   `workflow.monograph_search_phase_problem(...)`, og køen, uttaket og importen
   leser den samme.
3. Agenten vurderer de registrerte søkene og kandidatene, og ber om flere eller
   mer målrettede søk som strukturerte søkeforespørsler.
4. Kildene agenten velger til innhenting eller vurderer som mulig
   konklusjonsendrende, følger kjøringen selv i neste runde — referanselistene
   og de siterende arbeidene — uten at agenten må be om det.
5. Kjøringen utfører rundene, og agenten får neste vurderingsrunde. Budsjettet er
   fire runder per planversjon; et oppbrukt budsjett setter planen på pause som
   åpent, ventende arbeid — aldri som en konklusjon om evidensen.

Dekningskontrollen får sin egen maskinelle motsøkerunde, kjørt under **dens**
rolle og kjøring og med en annen strategi enn generatorens: målrettede
passeringer per akse der generatoren søkte bredt. `searched_independently`
utledes av søkeloggen og kan ikke lenger erklæres i svaret — en erklæring et
svar kan bestå ved å skrive den, kontrollerer ingenting.

En søkevei som ikke svarte, registreres som den begrensningen den er, prøves på
nytt, og holder ingenting tilbake: en tjeneste som er nede, skal ikke kunne
stanse arbeidet for alltid.

ChatGPT henter arbeid gjennom de private MCP-appene, én per ledd
([CHATGPT_WORKSPACE_AGENT.md](CHATGPT_WORKSPACE_AGENT.md)): fem verktøy, ingen
SQL, ingen generell databasevei. Ingen ny modellnøkkel og ingen betalt modell-API
er innført i fase C. Nedlast/opplast-veien (`npm run ops:agents -- export-task` /
`import-answer`) består som teknisk recovery.

**ChatGPT kan lede piloten uten å godkjenne sitt eget arbeid.** Det er ikke en
høflighetsregel, det er en databasegrense: den separate dekningskontrollen er et
annet ledd, med sin egen rolle, sin egen instruks og sin egen rollebundne
legitimasjon, og den kan ikke godta en dekning den ikke selv har søkt etter.
Sluttkontrollen krever et navngitt menneske med reviewer-mandat, og
publiseringen krever et *annet* menneske med publisher-mandat. Ingen agent kan
attestere at et menneske har vurdert innhold.

Grensen er en egen kjøring i en egen rolle — ikke en annen modell, og ikke en
annen Workspace Agent. De to leddene kan godt kjøre den samme modellen, og godt
være den samme agentkonfigurasjonen — men hvert med sin egen app i ChatGPT, fordi
plattformen knytter én tilkobling til én app. Det er en svakere påstand enn den forrige
utgaven av dette dokumentet gjorde, og den er den sanne: plattformen viser
normalt ikke hvilken modell en Workspace Agent kjører, så Antidep kunne uansett
aldri kontrollere at to oppgitte navn var to modeller.

De driftskommandoene som faktisk utfører søk og innhenting:

```
npm run ops:discovery                    # kildeoppdagelsens egne søk
npm run ops:discovery -- --leg coverage  # dekningskontrollens egne motsøk
npm run ops:discovery -- --plan <ref>    # bare én bestemt søkeplan, nå
npm run ops:acquire                      # henter originalmateriale der det er åpent tilgjengelig
```

Alle leser legitimasjonen sin fra miljøet, og alle registrerer gjennom de
kontrollerte skriveveiene. Ingen av dem startes for hånd i drift: søkene kjøres
planlagt av `.github/workflows/monograph-discovery.yml` to ganger i timen, med
ett steg per kildeledd. `ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke` viser at
de virker mot de ekte tjenestene.

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
  flyten med en tydelig avvisning framfor å gjette. Fra migrasjon 013t kan alle
  seks få **den samme** modellen: ett sant modellnavn er nok, og det er det
  sanne svaret når workspacet har én modellmeny. Fra migrasjon 013u er navnet i
  tildelingen proveniens og ikke adgangskontroll: agenten blir aldri bedt om å
  bevise hvilken modell den er, og et svar avvises ikke fordi den melder et
  annet navn om seg selv — eller ingen. De maskinelt utførte søkene
  (`npm run ops:discovery`) trenger ingen semantisk tildeling i det hele tatt —
  de kjører på kildeoppdagelsens registreringsidentitet, som migrasjonen seedet.
- **Kildeleddenes legitimasjon i drift.** `ANTIDEP_DISCOVERY_AGENT_*` og
  `ANTIDEP_COVERAGE_AGENT_*` må ligge som repository secrets for at de
  maskinelle søkene skal gå av seg selv. Mangler de, avslutter det planlagte
  steget grønt med en advarsel — og da står søkefasen, og den semantiske
  oppgaven kommer aldri, fordi den ikke skal komme før søkene er gjort.
- **Agentlegitimasjon.** Hvert kontrolledd har en egen identitet som er *inert*
  til legitimasjonen utstedes i det miljøet kjøreren leser hemmeligheten fra
  (`scripts/issue-agent-credential.sh`).
- **Utgiverens botvern.** Flere utgivere svarer 403 på en automatisk henting,
  også av åpen fulltekst. Det er en tilgangsbegrensning, ikke en faglig
  utelukkelse, og ikke en feil i koden. I praksis betyr det at en del
  forskningsfulltekst må lastes opp av et menneske gjennom `/fulltekst`.
  Forespørselen viser artikkelidentiteten og den faglige grunnen, samlet, slik
  at det ikke blir et klikk per artikkel.
- **Hva de maskinelle søkene ikke dekker.** Nettbaserte nasjonale råd
  (Helsedirektoratet, NICE, NHS SPS, Giftinformasjonen) har ingen åpen
  maskinell søkevei uten egen avtale, og heller ikke WHO ICTRP, EU CTR eller
  Cochrane CENTRAL. Det står som en begrensning ved sporet, i søkemetodens egen
  dekningsnote, og ikke som et spor noen må søke i for hånd. Er en slik kilde
  vesentlig for et spørsmål, sier kildeoppdagelsen det i merknaden.
- **Avkortede brede søk.** Det brede orienterende søket gir mange flere treff
  enn én side, og står derfor som avkortet. Stoppkravet holder dekningen åpen til
  det samme søket er lest helt, eller til et smalere søk med den samme metoden,
  som uttrykkelig erstatter det brede (`narrows_request`), er lest helt — det er
  kildeoppdagelsens søkeforespørsler, og ikke et menneske, som lukker det.
- **Norske aksetermer i engelske databaser.** Avgrensningens akser (indikasjon,
  utfall) har norske etiketter, og et fritekstsøk med dem gir ofte null treff i
  engelske databaser. Kildeoppdagelsen ser det i oppgaven og ber om målrettede
  søk med engelske termer; de nye søkemetodene søker på virkestoffets synonymer
  og ATC-kode og er ikke rammet.
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
npm run db:test                       # 82 filer, databaseprøvene
npm run db:test:monograph             # hele forløpet, fersk base
npm run db:test:monograph:upgrade     # samme forløp oppå en base med innhold
npm run test                          # flatene og modulene
npm run verify:repo                   # repokontrollene
ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke   # ekte søk, ekte innhenting
```

Den siste går ut på det åpne nettet og må bes om. Den er en teknisk røyktest og
ingen faglig prøve.
