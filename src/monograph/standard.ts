// ============================================================================
// Monografistandarden som maskinlesbar kontrakt
//
// `docs/MONOGRAPH_STANDARD.md` er den faglige fasiten, og den er skrevet for
// mennesker. Denne filen er den samme standarden uttrykt slik databasen,
// agentoppgavene og dekningskartet kan lese den: 80 stabile malidentiteter med
// kravtype, betingelse, svarform, kildeprofiler og de aksene malen gjentas på.
//
// ----------------------------------------------------------------------------
// Hvorfor dette ikke er et andre register
//
// Fordi ingenting her er skrevet av for hånd fra dokumentet. Verdiene er
// utledet av standardens egne tabeller, og `standard.test.ts` leser dokumentet
// på nytt og krever at hver eneste rad er den samme — kode for kode, kravtype
// for kravtype, profil for profil. Migrasjonen som seeder `monograph`-skjemaet,
// pinnes mot den samme listen (`standard-migration.test.ts`). Tre steder som
// ikke *kan* si forskjellige ting, er ikke tre registre: det er én kontrakt lest
// fra tre sider av en grense (samme form som `model-roles.ts` allerede har).
//
// En ny standardversjon er en ny versjon her og en ny rad i databasen. Den
// endrer aldri spørsmålet under et svar som allerede finnes: dekningskartet
// bærer versjonen det ble opprettet under.
// ============================================================================

/** Versjonen av den faglige standarden denne kontrakten uttrykker. */
export const MONOGRAPH_STANDARD_VERSION = '1.0.0'

/**
 * Kravtypen: obligatorisk å undersøke, betinget fordypning eller avledet
 * presentasjon.
 *
 * `mandatory` betyr at malen skal undersøkes, ikke at et positivt eller presist
 * svar må finnes. Skillet er standardens §3, og det er nettopp dette skillet
 * dekningskartet ikke får lov til å flate ut.
 */
export const REQUIREMENT_TYPES = ['mandatory', 'conditional', 'derived'] as const
export type RequirementType = (typeof REQUIREMENT_TYPES)[number]

/** Svarformene standardens §2 beskriver. */
export const ANSWER_FORMS = [
  'fact',
  'table',
  'estimate',
  'advice',
  'profile',
  'relation',
  'directed_relation',
  'summary',
  'derived',
] as const
export type AnswerForm = (typeof ANSWER_FORMS)[number]

/**
 * Aksene et behov avgrenses og gjentas på.
 *
 * Avgrensningen følger svaret: to svar kolliderer ikke fordi begge gjelder det
 * samme virkestoffet og det samme overordnede temaet, når indikasjon,
 * populasjon, dose, formulering, komparator eller tidsrom er forskjellig
 * (MONOGRAPH_STANDARD.md §2).
 */
export const SCOPE_AXES = [
  'product',
  'formulation',
  'indication',
  'population',
  'treatment_phase',
  'outcome',
  'comparator',
  'dose',
  'timeframe',
  'interaction_partner',
  'exposure',
  'comorbidity',
  'risk_area',
  'gene',
  'switch_target',
  'finding',
] as const
export type ScopeAxis = (typeof SCOPE_AXES)[number]

/** De 13 kildeprofilene i kildepolitikkens §3. */
export const SOURCE_PROFILE_CODES = [
  'REG',
  'PROD',
  'EFF',
  'AE',
  'SAFE',
  'POP',
  'INT',
  'PK',
  'PGX',
  'TDM',
  'STOP',
  'TOX',
  'SYN',
] as const
export type SourceProfileCode = (typeof SOURCE_PROFILE_CODES)[number]

export interface SourceProfile {
  readonly code: SourceProfileCode
  /** Hvilke spørsmål profilen gjelder. */
  readonly question: string
  /** Første kildevalg. */
  readonly firstChoice: string
  /** Hva som må suppleres, og hva som krever særskilt kontroll. */
  readonly supplement: string
}

export const SOURCE_PROFILES: readonly SourceProfile[] = [
  {
    code: 'REG',
    question: 'Norsk godkjenning, dosegrenser, kontraindikasjoner, preparathåndtering',
    firstChoice:
      'Gjeldende norsk myndighetsgodkjent preparatomtale, identifisert via DMP/Legemiddelsøk; relevant EMA-produktinformasjon når den gjelder produktet',
    supplement:
      'Faglige råd merkes separat. Behold forskjeller mellom produkter, formuleringer, indikasjoner og aldersgrupper. Kontroller at versjonen ikke er avløst.',
  },
  {
    code: 'PROD',
    question: 'Preparater, styrker, pakninger, markedsføring og refusjon',
    firstChoice:
      'Gjeldende DMP-legemiddeldata, FEST/FHIR der egnet og tilgjengelig, samt produktets preparatomtale',
    supplement:
      'Mangelsituasjon og lokal lagerstatus er egne forhold. Leverandørens faktiske datadekning og vilkår må kontrolleres før integrasjon. En synlig delestrek er ikke dokumentasjon på like deldoser.',
  },
  {
    code: 'EFF',
    question: 'Effekt, dose–respons, behandlingsfaser og sammenligning',
    firstChoice:
      'Relevante systematiske oversikter, eventuelt nettverksmetaanalyser, med lesbar metode og dekkende populasjon, komparator og utfall',
    supplement:
      'Oppdateringssøk etter oversiktens siste søkedato; sentrale primærstudier ved hull, motstrid eller behov for kontroll. Observasjonsstudier vurderes separat, ikke som automatisk erstatning for randomisering.',
  },
  {
    code: 'AE',
    question: 'Vanlige bivirkninger og behandlingsavbrudd',
    firstChoice:
      'Kontrollerte studier og systematiske oversikter med brukbare nevnere og registreringsmetoder; preparatomtalen som regulatorisk oversikt',
    supplement:
      'Skill aktiv utspørring fra spontanrapportering i en studie, varighet, dose og baselineplager. Frekvenskategorier fra forskjellige preparatomtaler er ikke en komparativ studie.',
  },
  {
    code: 'SAFE',
    question: 'Alvorlige, sjeldne eller vedvarende skader',
    firstChoice:
      'Preparatomtaler og myndighetenes sikkerhetsvurderinger, supplert med egnede oversikter, store observasjonsstudier og målrettede primærstudier',
    supplement:
      'Kasuistikker og meldesystemer kan gi signaler; de gir ikke alene insidens eller bevist årsak. Kontroller eksponering, nevner, tidsforløp, alternative forklaringer og mulig rapporteringsskjevhet (S11).',
  },
  {
    code: 'POP',
    question: 'Graviditet, amming, alder, organsvikt og komorbiditet',
    firstChoice:
      'REG for godkjenningsgrenser; relevante spesialistretningslinjer og systematiske oversikter/primærstudier i den aktuelle gruppen',
    supplement:
      'Teratologiske/laktasjonsfaglige oppslagsverk og norske faglige råd kan brukes som attribuert veiledning når versjon, begrunnelse og tilgang kan kontrolleres. Skill risiko ved behandling fra risiko ved sykdom og behandlingsstopp.',
  },
  {
    code: 'INT',
    question: 'Interaksjoner og praktisk håndtering',
    firstChoice:
      'REG og dokumenterte kliniske interaksjonsstudier; egnet nasjonal interaksjonsinformasjon og faglige retningslinjer',
    supplement:
      'Skill eksponeringsendring fra dokumentert klinisk utfall, in vitro fra mennesker og mekanisme fra håndteringsråd. Registrer begge virkestoffene, retning, dose, varighet og vedvarende virkning etter stopp.',
  },
  {
    code: 'PK',
    question: 'Farmakokinetikk og farmakodynamikk',
    firstChoice: 'REG og humane PK-/PD-studier, supplert med faglige synteser',
    supplement:
      'Arts-/in vitro-data merkes og kan ikke alene begrunne klinisk effekt. Behold dose, formulering, analytt/metabolitt, matriks, tidspunkt, studiepopulasjon og målemetode.',
  },
  {
    code: 'PGX',
    question: 'Genetikk og klinisk anvendelse',
    firstChoice:
      'Relevante CPIC-/DPWG-anbefalinger med identifisert versjon, supplert med REG og studiene anbefalingen bygger på',
    supplement:
      'Skill hvordan et eksisterende prøvesvar brukes fra hvem som bør testes. CPIC-dokumentet undersøkt her beskriver det første, ikke generell testindikasjon (S09). Behold uenighet mellom retningslinjer.',
  },
  {
    code: 'TDM',
    question: 'Konsentrasjonsmåling og fortolkning',
    firstChoice:
      'Identifiserte faglige TDM-retningslinjer og norske laboratoriers dokumenterte analyse-/fortolkningsveiledning; relevante PK- og kliniske studier',
    supplement:
      'Et laboratorieintervall, et konsensusbasert terapeutisk referanseområde og et dokumentert konsentrasjon–effekt-forhold er forskjellige. Registrer analytt, matriks, prøvetid, likevekt, enhet og metode.',
  },
  {
    code: 'STOP',
    question: 'Seponering, nedtrapping og bytte',
    firstChoice:
      'Relevante retningslinjer og faglige råd, inkludert NICE og NHS SPS der anvendelige; kontrollerte studier og oversikter når de finnes',
    supplement:
      'REG, PROD, PK og INT er tilleggskrav ved konkrete doser/bytteplaner. Skill veiledning og farmakologisk ekstrapolasjon fra empirisk sammenlignede strategier. Norske formuleringer må kontrolleres særskilt (S08, S10, S12).',
  },
  {
    code: 'TOX',
    question: 'Overdosering og forgiftningsrisiko',
    firstChoice:
      'Norske oppdaterte toksikologiske anbefalinger når tilgjengelige, REG og relevante humane forgiftningsstudier',
    supplement:
      'Skill terapeutisk bruk fra overdose, isolert inntak fra blandingsinntak, og klinisk risiko fra rapporteringsfrekvens. Akutt behandling er ikke en automatisk doseringsfunksjon i v1.',
  },
  {
    code: 'SYN',
    question: 'Kortoversikt og gjenbruk',
    firstChoice: 'Allerede kontrollerte svar på de underliggende spørsmålene',
    supplement:
      'Ingen ny ekstern faktakilde og ingen ny klinisk slutning i sammendragsleddet. Alle meningsbærende forbehold og avvik skal følge med.',
  },
]

export interface QuestionTemplate {
  /** Den stabile identiteten: MN01–MN80. Endres aldri. */
  readonly code: string
  /** Avsnittet i standarden malen hører under. */
  readonly section: string
  /** Spørsmålet og det minste svarinnholdet, ordrett fra standarden. */
  readonly prompt: string
  readonly requirement: RequirementType
  /** Kravkolonnen ordrett, fordi «O screening; B fordypning» ikke er bare «O». */
  readonly requirementText: string
  /** Betingelsen som aktiverer malen, eller null for et rent obligatorisk krav. */
  readonly condition: string | null
  /** Betinget fordypning etter en obligatorisk screening, eller null. */
  readonly conditionalDeepening: string | null
  readonly forms: readonly AnswerForm[]
  readonly sourceProfiles: readonly SourceProfileCode[]
  /**
   * Malen har ingen forhåndsbestemt kildeprofil: profilen følger av funnet.
   *
   * Gjelder MN80, og er ikke en åpning for et fritekstfelt uten kontroll —
   * hvert tillegg får avgrensning, kildeprofil, svarform, relevans og
   * dokumentasjon som øvrige behov (MONOGRAPH_STANDARD.md §3.14).
   */
  readonly openSourceProfiles: boolean
  /** Aksene malen gjentas på når avgrensningen krever det. */
  readonly expansionAxes: readonly ScopeAxis[]
}

export const QUESTION_TEMPLATES: readonly QuestionTemplate[] = [
  {
    code: 'MN01',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilket virkestoff gjelder dette? Kanonisk navn, relevante synonymer, virkestoff-/saltangivelse og identifikatorer; kombinasjonspreparater skilles ut.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['fact'],
    sourceProfiles: ['REG', 'PROD'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN02',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilken klasse og hvilke dokumenterte virkningsmekanismer har det? Skill etablert farmakologi fra hypoteser om klinisk effekt.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['REG', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN03',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilke norske produkter finnes? Handelsnavn, formulering, administrasjonsvei, styrke og relevant pakningsidentitet.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN04',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Er produktene markedsført, avregistrert eller omfattet av kjente leveringsbegrensninger? Datakilde og tidspunkt; ikke påstå lokal lagerstatus.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN05',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvordan kan hvert produkt håndteres? Like deldoser, svelging, knusing, åpning, oppløsning eller fortynning; «ikke dokumentert» må kunne vises.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG', 'PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN06',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilke hjelpestoffer, væskekonsentrasjoner, måleredskaper eller administrasjonsforhold har praktisk klinisk betydning?',
    requirement: 'mandatory',
    requirementText: 'O; detaljposter bare ved relevant forhold',
    condition: 'detaljposter bare ved relevant forhold',
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG', 'PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN07',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilke små doser kan faktisk gis med dokumenterte norske produktmuligheter? Skill ordinært markedsførte, importerte og apotektilvirkede alternativer.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['PROD', 'REG'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN08',
    section: '3.1 Identitet og norske preparater',
    prompt:
      'Hvilke norske refusjonsvilkår er relevante for aktuelle produkter/indikasjoner? Skill refusjon fra godkjenning og oppgi kontrolltidspunkt.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product', 'indication'],
  },
  {
    code: 'MN09',
    section: '3.2 Indikasjoner og behandlingsrolle',
    prompt:
      'Hvilke indikasjoner og aldersgrupper er godkjent i Norge for relevante produkter? Behold ordlyd og avgrensning.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN10',
    section: '3.2 Indikasjoner og behandlingsrolle',
    prompt:
      'Hvilken annen klinisk relevant bruk bør vurderes? Indikasjon, begrunnelse for inkludering, evidens og eventuelle frarådinger; ikke likestill bruk med anbefaling.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['EFF', 'POP', 'REG'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN11',
    section: '3.2 Indikasjoner og behandlingsrolle',
    prompt:
      'Hvilken plass har virkestoffet i relevante behandlingsanbefalinger? Første/senere behandlingsvalg, monoterapi/tillegg og hvilke pasienter rådet gjelder.',
    requirement: 'conditional',
    requirementText: 'B: identifisert godkjent eller relevant annen indikasjon',
    condition: 'identifisert godkjent eller relevant annen indikasjon',
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['EFF', 'POP'],
    openSourceProfiles: false,
    expansionAxes: ['indication'],
  },
  {
    code: 'MN12',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hvor stor er endringen i relevante symptomer sammenlignet med komparator? Instrument, absolutt/standardisert forskjell, tidsrom og presisjon.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['estimate'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN13',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hvor mange oppnår respons? Kildens responsdefinisjon, hendelser/nevnere og absolutt/relativ forskjell.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['estimate'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN14',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hvor mange oppnår remisjon? Definisjon, varighet og sammenligning; ikke bytt ut med respons.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['estimate'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN15',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hva er dokumentert om tid til bedring eller klinisk viktig effekt? Skill første statistiske utslag fra pasientrelevant bedring.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['estimate', 'summary'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN16',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hva er effekten på funksjon, livskvalitet og andre pasientviktige utfall? Ikke utled disse av symptomskår alene.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN17',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hva er dokumentert om fortsatt behandling og tilbakefalls-/residivforebygging? Utvalgsberikelse, tidligere respons, varighet og seponering i kontrollarmen.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon der videre behandling er aktuelt',
    condition: 'aktiv indikasjon der videre behandling er aktuelt',
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['EFF', 'STOP'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN18',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hvordan varierer nytte og belastning med dose? Skill dose–respons-data fra godkjent doseområde og farmakologiske antakelser.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['EFF', 'AE'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN19',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hva vet vi ved tidligere utilstrekkelig effekt eller behandlingsresistens? Behold definisjon, antall tidligere forsøk og mono-/tilleggsbehandling.',
    requirement: 'conditional',
    requirementText: 'B: relevant behandlingssituasjon identifisert',
    condition: 'relevant behandlingssituasjon identifisert',
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'outcome'],
  },
  {
    code: 'MN20',
    section: '3.3 Dokumentert effekt',
    prompt:
      'Hva kan faktisk sammenlignes med andre antidepressiver? Navngitt par, direkte/indirekte grunnlag, utfall, tidsrom, forskjell og usikkerhet.',
    requirement: 'conditional',
    requirementText: 'B: aktiv indikasjon',
    condition: 'aktiv indikasjon',
    conditionalDeepening: null,
    forms: ['estimate', 'summary'],
    sourceProfiles: ['EFF'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'comparator', 'outcome'],
  },
  {
    code: 'MN21',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hva er godkjent startdose per indikasjon, alder og formulering, og finnes separate faglige råd?',
    requirement: 'mandatory',
    requirementText: 'O; gjentas per relevant bruk',
    condition: 'gjentas per relevant bruk',
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG', 'POP'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'population', 'formulation'],
  },
  {
    code: 'MN22',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hvordan titreres behandlingen? Trinn, minste intervall, vurderingspunkter og dosebegrensende forhold; merk rådets opphav.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'POP'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN23',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hva er vanlig behandlingsområde og godkjent maksimaldose? Avgrens til produkt, indikasjon og gruppe; høyere faglig foreslått dose er et separat utsagn.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG', 'EFF', 'POP'],
    openSourceProfiles: false,
    expansionAxes: ['indication', 'population'],
  },
  {
    code: 'MN24',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hvordan tas legemidlet? Doseringshyppighet, tidspunkt, mat og praktisk administrasjon; koble til MN05.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'PK'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN25',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hvilke dokumenterte råd gjelder glemt dose, behandlingsavbrudd og eventuell gjenoppstart? Ikke gi én regel for alle avbruddslengder.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'STOP'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN26',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hva bør avklares før oppstart? Relevante symptomer/risikofaktorer, legemidler, undersøkelser og prøver; rutinekrav skilles fra risikobasert kontroll.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'SAFE', 'POP'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN27',
    section: '3.4 Dosering, oppstart og oppfølging',
    prompt:
      'Hva bør følges opp, når og med hvilke reaksjoner på funn? Effekt, tolerabilitet, sikkerhet og behandlingsvarighet; kildegrunnlag for eventuelle terskler.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'EFF', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN28',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om seksuell funksjon? Lyst, opphisselse, orgasme og andre relevante delutfall; baselineplager og målemetode.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN29',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om vekt og appetitt? Endring i kg/prosent, klinisk definert vektøkning/-tap og tidsforløp holdes atskilt.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN30',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om søvn og våkenhet? Søvnighet, tretthet, søvnløshet og søvnkvalitet er egne delutfall.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN31',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om aktivering, uro, angstforverring og akatisi? Skill tidlig reaksjon, vedvarende plager og grunnsykdom.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN32',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om gastrointestinale plager? Kvalme, oppkast, diaré og obstipasjon vurderes hver for seg.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN33',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om svette, munntørrhet og andre autonome/antikolinerge plager? Ikke utled hele profilen av reseptorbinding alene.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN34',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hva vet vi om kognisjon, emosjonell avflatning og daglig funksjon som mulige bivirkninger? Skill sykdomseffekt og legemiddeleffekt.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN35',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hvilke andre vanlige eller særlig plagsomme bivirkninger er relevante? Eksempelvis hodepine, svimmelhet og tremor; opprett navngitte delutfall.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['AE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN36',
    section: '3.5 Klinisk bivirkningsprofil',
    prompt:
      'Hvor ofte avsluttes behandling på grunn av bivirkninger, og hvor ofte uansett årsak? Separate utfall med tidsrom og komparator.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['estimate'],
    sourceProfiles: ['AE', 'EFF'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN37',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Hvilke kontraindikasjoner og vesentlige forholdsregler gjelder? Skill absolutt kontraindikasjon fra forsiktighet og manglende data.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['table'],
    sourceProfiles: ['REG', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN38',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Hva er dokumentert om hvert forhåndsdefinert alvorlig risikoområde nedenfor? Risiko, disponerende forhold, kunnskapstype og praktisk konsekvens.',
    requirement: 'mandatory',
    requirementText: 'O; ett behov per risikoområde',
    condition: 'ett behov per risikoområde',
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['SAFE', 'REG'],
    openSourceProfiles: false,
    expansionAxes: ['risk_area', 'outcome'],
  },
  {
    code: 'MN39',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Hva vet vi om suicidalitet og selvskading? Alder, behandlingsfase, grunnrisiko, hendelsesdefinisjon og datakilde; absolutt risiko når mulig.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['SAFE', 'EFF'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN40',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Finnes dokumentasjon på vedvarende symptomer eller skader etter avslutning? Skill sikkerhetssignal, observasjon og etablert risiko.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['SAFE', 'STOP'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN41',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Hvilken betydning har behandlingen for kjøring, maskiner og sikkerhetskritisk arbeid? Klinisk påvirkning skilles fra eventuelle norske rettslige helsekrav.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN42',
    section: '3.6 Alvorlig risiko og forholdsregler',
    prompt:
      'Hvilke faresignaler eller funn krever rask vurdering, behandlingsendring eller spesialistkontakt? Koble rådet til den konkrete risikoen.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['REG', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN43',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder for barn og ungdom? Indikasjon, aldersgrupper, nytte, risiko og godkjent/annen bruk.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'REG'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN44',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder for eldre og skrøpelige? Dose, effektgrunnlag, multimorbiditet, fall, natrium og annen relevant oppfølging.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN45',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder i svangerskap? Tidlig/sen eksponering, foster-/svangerskaps-/neonatale utfall og risiko ved grunnsykdom/stopp; vurder videreføring separat fra nyoppstart.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN46',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder ved amming? Melkeovergang og barnets eksponering/utfall, alder/prematuritet og praktisk oppfølging; ett eksponeringsmål er ikke alene en trygghetsdom.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN47',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva vet vi om fertilitet og bruk rundt konsepsjon hos relevante grupper? Human dokumentasjon skilles fra dyredata og fra seksuelle bivirkninger.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN48',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder ved nedsatt leverfunksjon? Kildens alvorlighetsinndeling, dose, kontraindikasjoner og oppfølging.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'REG', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN49',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hva gjelder ved nedsatt nyrefunksjon eller dialyse? Kildens funksjonsmål, terskler/enheter, aktive metabolitter og dose-/oppfølgingsråd.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['POP', 'REG', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN50',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hvilke psykiatriske tilleggstilstander endrer vurderingen? Minst bipolaritet/mani, psykose, rusmiddelproblemer og relevante angsttilstander undersøkes; utdyp ved betydning.',
    requirement: 'mandatory',
    requirementText: 'O screening; B fordypning',
    condition: null,
    conditionalDeepening: 'B fordypning',
    forms: ['profile'],
    sourceProfiles: ['POP', 'SAFE', 'EFF'],
    openSourceProfiles: false,
    expansionAxes: ['comorbidity', 'outcome'],
  },
  {
    code: 'MN51',
    section: '3.7 Særlige pasientgrupper',
    prompt:
      'Hvilke somatiske forhold endrer vurderingen? Minst hjerte-/karsykdom, epilepsi, blødningsrisiko, metabolsk sykdom, glaukom/urinretensjon og endret gastrointestinal anatomi/absorpsjon vurderes.',
    requirement: 'mandatory',
    requirementText: 'O screening; B fordypning',
    condition: null,
    conditionalDeepening: 'B fordypning',
    forms: ['profile'],
    sourceProfiles: ['POP', 'REG', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['comorbidity', 'outcome'],
  },
  {
    code: 'MN52',
    section: '3.8 Interaksjoner',
    prompt:
      'Hvilke enzymer/transportører er relevante for substrat-, hemmer- eller induserrolle? Dokumentert klinisk betydning og styrke skilles fra in vitro-funn.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['INT', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN53',
    section: '3.8 Interaksjoner',
    prompt:
      'Hvilke farmakokinetiske kombinasjoner har praktisk betydning? Motpart, påvirket stoff, eksponeringsendring, klinisk utfall/råd og tidsforløp.',
    requirement: 'conditional',
    requirementText: 'B: identifisert relevant kombinasjon',
    condition: 'identifisert relevant kombinasjon',
    conditionalDeepening: null,
    forms: ['relation'],
    sourceProfiles: ['INT'],
    openSourceProfiles: false,
    expansionAxes: ['interaction_partner'],
  },
  {
    code: 'MN54',
    section: '3.8 Interaksjoner',
    prompt:
      'Hvilke farmakodynamiske kombinasjoner krever handling? Kontraindikasjon, unngåelse, dose-/monitoreringsråd og begrunnelse.',
    requirement: 'mandatory',
    requirementText: 'O screening; B per kombinasjon',
    condition: null,
    conditionalDeepening: 'B per kombinasjon',
    forms: ['relation'],
    sourceProfiles: ['INT', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: ['interaction_partner'],
  },
  {
    code: 'MN55',
    section: '3.8 Interaksjoner',
    prompt:
      'Hvilke interaksjoner gjelder mat, alkohol, andre rusmidler, røykestatus og natur-/kosttilskudd? Ikke gi generelle frikjennelser når data mangler.',
    requirement: 'mandatory',
    requirementText: 'O screening; B per relevant eksponering',
    condition: null,
    conditionalDeepening: 'B per relevant eksponering',
    forms: ['relation'],
    sourceProfiles: ['INT'],
    openSourceProfiles: false,
    expansionAxes: ['exposure'],
  },
  {
    code: 'MN56',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hva vet vi om absorpsjon? Biotilgjengelighet, Tmax, mat-/formuleringseffekt, undersøkt dose og populasjon.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN57',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hva vet vi om distribusjon? Distribusjonsvolum og proteinbinding, samt dokumentert klinisk betydning.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN58',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hvordan metaboliseres og elimineres stoffet? Relevante enzymer, uendret renal utskillelse, metabolittdannelse og datagrunnlag.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN59',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hvilke metabolitter bidrar farmakologisk? Aktivitet, eksponering, halveringstid og klinisk betydning; ingen automatisk likestilling med moderstoffet.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN60',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hvilke halveringstider er relevante? Moderstoff/metabolitt, enkelt-/gjentatt dose, terminal/annen fase og populasjon.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['estimate', 'profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN61',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hva vet vi om likevekt, akkumulering og doseproporsjonalitet? Målte funn skilles fra modellberegninger.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['PK'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN62',
    section: '3.9 Farmakokinetikk og utdypende farmakologi',
    prompt:
      'Hvilke eksponerings-/PD-forhold har praktisk betydning utover dette? Doseavhengig hemming, vedvarende farmakologisk effekt eller klinisk relevante reseptor-/transportørdata når dokumentert.',
    requirement: 'mandatory',
    requirementText: 'O screening; B fordypning',
    condition: null,
    conditionalDeepening: 'B fordypning',
    forms: ['profile'],
    sourceProfiles: ['PK', 'INT'],
    openSourceProfiles: false,
    expansionAxes: ['finding', 'outcome'],
  },
  {
    code: 'MN63',
    section: '3.10 TDM og farmakogenetikk',
    prompt:
      'Når kan konsentrasjonsmåling være nyttig, og hva kan den ikke avklare? Klinisk indikasjon og evidens/veiledning.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['TDM'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN64',
    section: '3.10 TDM og farmakogenetikk',
    prompt:
      'Hvordan tas og tolkes prøven? Analytt eller sum, matriks, prøvetid, likevekt, enheter, referanseområde og begrensninger.',
    requirement: 'conditional',
    requirementText: 'B: relevant TDM-anvendelse',
    condition: 'relevant TDM-anvendelse',
    conditionalDeepening: null,
    forms: ['table', 'advice'],
    sourceProfiles: ['TDM', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['finding'],
  },
  {
    code: 'MN65',
    section: '3.10 TDM og farmakogenetikk',
    prompt:
      'Hvordan kan et eksisterende genetisk resultat påvirke valg/dose? Gen, fenotype, eksakt retningslinjeversjon, interaksjoner/fenokonversjon og usikkerhet.',
    requirement: 'mandatory',
    requirementText: 'O screening; B per relevant gen–legemiddel-par',
    condition: null,
    conditionalDeepening: 'B per relevant gen–legemiddel-par',
    forms: ['relation', 'advice'],
    sourceProfiles: ['PGX'],
    openSourceProfiles: false,
    expansionAxes: ['gene'],
  },
  {
    code: 'MN66',
    section: '3.10 TDM og farmakogenetikk',
    prompt:
      'Når bør testing vurderes, og er klinisk nytte av teststrategien undersøkt? Ikke utled testindikasjon fra MN65 alene.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['PGX', 'EFF'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN67',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hvilke seponeringssymptomer, forekomster og tidsforløp er dokumentert? Tidligere behandlingslengde, dose, seponeringsmåte og registreringsmetode.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['STOP', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN68',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hva påvirker risiko eller behov for langsommere nedtrapping? Dokumentasjon for dose, varighet, tidligere erfaring og øvrige forhold.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['STOP'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN69',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hvordan vurderes mulig seponering, tilbakefall og annen årsak? Typiske kjennetegn, begrensninger og oppfølging; ingen sikker automatisk klassifikasjon.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['STOP'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN70',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hvilke nedtrappingsprinsipper er anbefalt og/eller undersøkt? Reduksjonsgrunnlag, trinn, intervaller, pauser og tilpasning etter symptomer.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['STOP'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN71',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hvordan kan et dokumentert prinsipp realiseres med norske produkter? Kobling til MN05–MN07, faktiske doser og begrensninger, ikke bare ideelle prosenttrinn.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['relation', 'summary'],
    sourceProfiles: ['STOP', 'REG', 'PROD'],
    openSourceProfiles: false,
    expansionAxes: ['product'],
  },
  {
    code: 'MN72',
    section: '3.11 Seponering og nedtrapping',
    prompt:
      'Hvilken oppfølging og håndtering anbefales ved plager under/etter nedtrapping? Pause, ny vurdering, eventuell endring og når spesialist bør involveres.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['STOP', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN73',
    section: '3.12 Bytte mellom antidepressiver',
    prompt:
      'Hvilken strategi er dokumentert/anbefalt fra A til B? Retning, dose-/formuleringsforutsetninger, direkte bytte, nedtrapping, overlapp eller legemiddelfritt intervall.',
    requirement: 'conditional',
    requirementText: 'B: bestilt eller klinisk relevant identifisert byttepar',
    condition: 'bestilt eller klinisk relevant identifisert byttepar',
    conditionalDeepening: null,
    forms: ['directed_relation'],
    sourceProfiles: ['STOP', 'REG', 'INT', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['switch_target'],
  },
  {
    code: 'MN74',
    section: '3.12 Bytte mellom antidepressiver',
    prompt:
      'Hvilke overlapp eller intervaller er kontraindisert, nødvendige eller usikre? Begrunnelse, aktive metabolitter og vedvarende farmakologisk virkning.',
    requirement: 'conditional',
    requirementText: 'B: samme byttepar som MN73',
    condition: 'samme byttepar som MN73',
    conditionalDeepening: null,
    forms: ['directed_relation'],
    sourceProfiles: ['STOP', 'REG', 'INT', 'PK'],
    openSourceProfiles: false,
    expansionAxes: ['switch_target'],
  },
  {
    code: 'MN75',
    section: '3.12 Bytte mellom antidepressiver',
    prompt:
      'Hva skal følges opp under og etter dette byttet, og når skal planen ikke brukes? Seponering, tilbakefall, interaksjoner og særgrupper.',
    requirement: 'conditional',
    requirementText: 'B: samme byttepar som MN73',
    condition: 'samme byttepar som MN73',
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['STOP', 'POP', 'SAFE'],
    openSourceProfiles: false,
    expansionAxes: ['switch_target'],
  },
  {
    code: 'MN76',
    section: '3.13 Overdosering og toksisitet',
    prompt:
      'Hvilke forgiftningsbilder og tidsforløp er relevante? Formulering, dose når kjent, isolert/blandet inntak og usikkerhet.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['TOX'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN77',
    section: '3.13 Overdosering og toksisitet',
    prompt:
      'Hva vet vi om alvorlighetsgrad ved overdose og eventuelle forskjeller fra andre antidepressiver? Sammenlignbare data, eksponeringsgrunnlag og begrensninger.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: ['TOX'],
    openSourceProfiles: false,
    expansionAxes: ['outcome'],
  },
  {
    code: 'MN78',
    section: '3.13 Overdosering og toksisitet',
    prompt:
      'Hvilke faresignaler og norske faglige ressurser skal klinikeren henvises til? Ikke erstatt akutt vurdering med en beregnet «trygg dose».',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['advice'],
    sourceProfiles: ['TOX', 'REG'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN79',
    section: '3.14 Samlet klinisk oversikt og blindsoner',
    prompt:
      'Hva er de viktigste kliniske egenskapene, begrensningene og kunnskapshullene i denne utgaven? Kortversjon fra kontrollerte svar, uten udokumentert rangering.',
    requirement: 'derived',
    requirementText: 'A: bygges når underliggende svar finnes',
    condition: 'bygges når underliggende svar finnes',
    conditionalDeepening: null,
    forms: ['derived'],
    sourceProfiles: ['SYN'],
    openSourceProfiles: false,
    expansionAxes: [],
  },
  {
    code: 'MN80',
    section: '3.14 Samlet klinisk oversikt og blindsoner',
    prompt:
      'Finnes andre klinisk viktige forhold standardfeltene ikke fanger? Åpent sikkerhets-/særtrekksøk; opprett navngitte behov ved funn.',
    requirement: 'mandatory',
    requirementText: 'O',
    condition: null,
    conditionalDeepening: null,
    forms: ['profile'],
    sourceProfiles: [],
    openSourceProfiles: true,
    expansionAxes: ['finding', 'outcome'],
  },
]

// ----------------------------------------------------------------------------
// De verdiene standarden selv navngir
//
// Fire maler er screeningsspørsmål med en liste standarden skriver ut: MN38
// navngir elleve alvorlige risikoområder, MN50 fire psykiatriske
// tilleggstilstander, MN51 seks somatiske forhold og MN55 fem eksponeringer.
// De er ikke funn en agent skal finne på — de er spørsmål som skal stilles
// uansett hva svaret blir, og listen er standardens egen
// (MONOGRAPH_STANDARD.md §3.6, §3.7, §3.8).
//
// Derfor får de hvert sitt behov med én gang, framfor å vente på at noe blir
// dokumentert. «MN38 skal minst vurdere …» er et krav om å undersøke, ikke en
// erklæring om at hvert virkestoff gir hver risiko.
// ----------------------------------------------------------------------------

export interface PrescribedScopeValue {
  /** Malen verdien hører til. */
  readonly template: string
  readonly axis: ScopeAxis
  /** Verdien slik standarden navngir den. */
  readonly label: string
}

export const PRESCRIBED_SCOPE_VALUES: readonly PrescribedScopeValue[] = [
  // MN38 — §3.6: de elleve alvorlige risikoområdene screeningen minst dekker.
  { template: 'MN38', axis: 'risk_area', label: 'rytme-/ledningsforstyrrelser og QT' },
  { template: 'MN38', axis: 'risk_area', label: 'blodtrykksendring/ortostase' },
  { template: 'MN38', axis: 'risk_area', label: 'hyponatremi' },
  { template: 'MN38', axis: 'risk_area', label: 'blødning' },
  { template: 'MN38', axis: 'risk_area', label: 'kramper' },
  { template: 'MN38', axis: 'risk_area', label: 'mani/hypomani' },
  { template: 'MN38', axis: 'risk_area', label: 'serotonerg toksisitet' },
  { template: 'MN38', axis: 'risk_area', label: 'lever-/annen organskade' },
  { template: 'MN38', axis: 'risk_area', label: 'alvorlige overfølsomhetsreaksjoner' },
  { template: 'MN38', axis: 'risk_area', label: 'fall' },
  {
    template: 'MN38',
    axis: 'risk_area',
    label: 'klinisk betydningsfull antikolinerg belastning',
  },

  // MN50 — §3.7: de psykiatriske tilleggstilstandene som minst undersøkes.
  { template: 'MN50', axis: 'comorbidity', label: 'bipolaritet/mani' },
  { template: 'MN50', axis: 'comorbidity', label: 'psykose' },
  { template: 'MN50', axis: 'comorbidity', label: 'rusmiddelproblemer' },
  { template: 'MN50', axis: 'comorbidity', label: 'relevante angsttilstander' },

  // MN51 — §3.7: de somatiske forholdene som minst vurderes.
  { template: 'MN51', axis: 'comorbidity', label: 'hjerte-/karsykdom' },
  { template: 'MN51', axis: 'comorbidity', label: 'epilepsi' },
  { template: 'MN51', axis: 'comorbidity', label: 'blødningsrisiko' },
  { template: 'MN51', axis: 'comorbidity', label: 'metabolsk sykdom' },
  { template: 'MN51', axis: 'comorbidity', label: 'glaukom/urinretensjon' },
  {
    template: 'MN51',
    axis: 'comorbidity',
    label: 'endret gastrointestinal anatomi/absorpsjon',
  },

  // MN55 — §3.8: eksponeringene interaksjonsscreeningen minst dekker.
  { template: 'MN55', axis: 'exposure', label: 'mat' },
  { template: 'MN55', axis: 'exposure', label: 'alkohol' },
  { template: 'MN55', axis: 'exposure', label: 'andre rusmidler' },
  { template: 'MN55', axis: 'exposure', label: 'røykestatus' },
  { template: 'MN55', axis: 'exposure', label: 'natur-/kosttilskudd' },
]

// ----------------------------------------------------------------------------
// Søkesporene kildepolitikkens §4.2 krever forsøkt og dokumentert
//
// Sporene er *minimumsdekningen* per profil, ikke en anbefaling. Et spor som
// ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig; et spor som er
// forsøkt og var utilgjengelig, er en registrert begrensning og ikke null treff
// (SOURCE_POLICY.md §4.2, §8.1).
// ----------------------------------------------------------------------------

export interface SearchTrack {
  readonly code: string
  /** Profilene sporet er obligatorisk for. */
  readonly profiles: readonly SourceProfileCode[]
  readonly label: string
}

export const SEARCH_TRACKS: readonly SearchTrack[] = [
  {
    code: 'norwegian_authority_source',
    profiles: ['REG', 'PROD'],
    label: 'Direkte kontroll i relevant norsk myndighetskilde og kildeversjon',
  },
  {
    code: 'all_identified_products',
    profiles: ['REG', 'PROD'],
    label: 'Alle identifiserte relevante produkter og formuleringer',
  },
  {
    code: 'change_and_shortage_check',
    profiles: ['REG', 'PROD'],
    label: 'Kontroll av endrings- og mangelopplysninger når slike skal vises',
  },
  {
    code: 'bibliographic_database',
    profiles: ['EFF', 'AE', 'SAFE', 'POP', 'PK', 'INT', 'PGX', 'TDM', 'STOP', 'TOX'],
    label: 'PubMed/MEDLINE eller et tilsvarende bibliografisk søk',
  },
  {
    code: 'systematic_review_search',
    profiles: ['EFF', 'AE', 'SAFE', 'POP', 'STOP', 'TOX'],
    label: 'Et særskilt oversiktssøk',
  },
  {
    code: 'independent_second_database',
    profiles: ['EFF', 'AE'],
    label: 'Et supplerende uavhengig søkespor, som CENTRAL eller en egnet annen database',
  },
  {
    code: 'reference_lists',
    profiles: ['EFF', 'AE', 'PK', 'INT'],
    label: 'Referanselister for sentrale kilder',
  },
  {
    code: 'citing_works',
    profiles: ['EFF', 'AE'],
    label: 'Nyere siterende arbeider for sentrale kilder',
  },
  {
    code: 'trial_registries',
    profiles: ['EFF', 'AE'],
    label: 'Forsøksregistre, for oversette, uavsluttede eller upubliserte studier',
  },
  {
    code: 'regulatory_or_specialist_guidance',
    profiles: ['SAFE', 'POP', 'STOP', 'TOX', 'PGX', 'TDM'],
    label: 'Relevant regulatorisk eller spesialisert veiledning',
  },
  {
    code: 'observational_safety_search',
    profiles: ['SAFE', 'POP'],
    label: 'Målrettet søk etter egnede observasjons- og sikkerhetsdata',
  },
  {
    code: 'product_information',
    profiles: ['PK', 'INT'],
    label: 'Preparatomtalen for de relevante produktene',
  },
  {
    code: 'human_primary_studies',
    profiles: ['PK', 'INT'],
    label: 'Målrettet søk etter humane originalstudier',
  },
  {
    code: 'update_search',
    profiles: ['PGX', 'TDM'],
    label: 'Oppdateringssøk etter nye eller motstridende studier',
  },
  {
    code: 'dependent_profile_controls',
    profiles: ['STOP'],
    label: 'Nødvendige REG-, PROD-, PK- og INT-kontroller for konkrete tiltak',
  },
  {
    code: 'reuse_validity_check',
    profiles: ['SYN'],
    label: 'Kontroll av at hvert brukt svar fortsatt gjelder den samme avgrensningen',
  },
]

// ----------------------------------------------------------------------------
// Oppslag
// ----------------------------------------------------------------------------

const TEMPLATES_BY_CODE = new Map<string, QuestionTemplate>(
  QUESTION_TEMPLATES.map((t) => [t.code, t]),
)
const PROFILES_BY_CODE = new Map<string, SourceProfile>(SOURCE_PROFILES.map((p) => [p.code, p]))

/** Malen, eller et kast som navngir koden framfor å gi en udefinert verdi. */
export function questionTemplate(code: string): QuestionTemplate {
  const template = TEMPLATES_BY_CODE.get(code)
  if (template === undefined) {
    throw new Error(
      `Spørsmålsmalen «${code}» finnes ikke i monografistandard ${MONOGRAPH_STANDARD_VERSION}. ` +
        'Malidentitetene er stabile: MN01–MN80.',
    )
  }
  return template
}

export function sourceProfile(code: string): SourceProfile {
  const profile = PROFILES_BY_CODE.get(code)
  if (profile === undefined) {
    throw new Error(
      `Kildeprofilen «${code}» finnes ikke. Profilene er ${SOURCE_PROFILE_CODES.join(', ')}.`,
    )
  }
  return profile
}

/** Sporene som må være forsøkt og dokumentert for en profil. */
export function requiredSearchTracks(profile: SourceProfileCode): readonly SearchTrack[] {
  return SEARCH_TRACKS.filter((track) => track.profiles.includes(profile))
}

/** Verdiene standarden selv navngir for én mal, eller en tom liste. */
export function prescribedScopeValues(code: string): readonly PrescribedScopeValue[] {
  return PRESCRIBED_SCOPE_VALUES.filter((value) => value.template === code)
}
