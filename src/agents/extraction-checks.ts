// ============================================================================
// Den deterministiske ekstraksjonskontrollen
//
// ANTIDEP_CONSTITUTION.md §11: «Før en KI-generert syntese kan godkjennes, skal
// en separat kontrollfase aktivt lete etter feilsitering, overtolkning,
// manglende forbehold, motstridende forskning, feil populasjon eller endepunkt,
// utdaterte kilder og numeriske avvik.» Denne modulen dekker to av dem — de to
// som faktisk kan avgjøres av en maskin uten å tolke språk: **feilsitering** og
// **numeriske avvik**.
//
// ----------------------------------------------------------------------------
// Hvorfor kontrollen er deterministisk og ikke et språkmodellkall
//
// ANTIDEP_CONSTITUTION.md §17 sier at kliniske kontroller skal være
// deterministiske «der det er mulig», og for nettopp sitat- og tallkontroll er
// det mulig — og strengere enn en språkmodell. Et sitat står enten ordrett i
// kilden eller ikke; et tall står der eller ikke. En modell som «vurderer» det,
// legger til usikkerhet uten å legge til noe.
//
// §20 er samtidig oppfylt: kjøringen registrerer leverandør, modell og
// modellversjon som ethvert annet agentledd (provenance.agent_runs), så et
// senere ledd med språkmodell er et nytt adapter og ikke en ny datamodell.
//
// ----------------------------------------------------------------------------
// Hva kontrollen KAN og hva den IKKE KAN
//
// Den kan bekrefte at noe **står** i kilden. Den kan i all hovedsak ikke
// bekrefte at noe **ikke** står der, og asymmetrien avgjør hva hvert utfall
// betyr:
//
//   * Et sitat som ikke finnes ordrett  →  et avvik, og utfallet blir
//     needs_correction. Et sitat er en påstand om ordrett gjengivelse fra
//     nøyaktig den representasjonen raden peker på, og den påstanden er
//     falsifiserbar: er teksten ikke der, er den ikke der.
//   * Et oppgitt tall som ikke finnes   →  ikke et avvik, men en kontroll som
//     ikke konkluderte. Utfallet blir uncertain, og feltet føres ikke opp som
//     kontrollert. Grunnen er at et tall kan stå i kilden på former søket ikke
//     ser: skrevet med bokstaver («Thirty-one HV»), i en annen enhet, eller i
//     en tabell som ikke er med i den hentede representasjonen. Å kalle det et
//     avvik ville produsert falske anklager mot riktige ekstraksjoner — og en
//     verifikator som roper ulv, er verre enn ingen verifikator.
//   * Et begrep som ikke finnes         →  verken avvik eller utfall. Kildene
//     er på engelsk og katalogen på norsk, så et manglende treff på
//     «vektendring» sier ingenting. Feltet føres ikke opp som kontrollert.
//
// De to siste er hele grunnen til at `checked_fields` finnes: en bekreftelse
// skal dekke det den gir inntrykk av å dekke (DATABASE_ARCHITECTURE.md §29). Et
// felt kontrollen ikke kunne avgjøre, føres aldri opp som kontrollert — og et
// utfall som ikke konkluderte, skal aldri leses som en bekreftelse
// (ANTIDEP_CONSTITUTION.md §6, §11).
//
// ----------------------------------------------------------------------------
// Kildeforankringen er den ene siden maskinen skal bevise
//
// Fra migrasjon 005u av leverer ekstraksjonen ett ordrett utdrag, én presis
// peker og én kort begrunnelse per semantisk felt. Utdraget er venstresiden i
// kontrolløkten, og det er nettopp den maskinen kan avgjøre: står teksten
// ordrett i den kildeversjonen raden peker på, eller ikke?
//
// Arbeidsdelingen er derfor skarp. Maskinen beviser at venstresiden faktisk
// kommer fra kilden; mennesket vurderer om høyresiden — den strukturerte
// verdien — følger av venstresiden. Et forankringsutdrag som ikke står i
// representasjonen, er et avvik av samme slag som et sitat som ikke gjør det:
// påstanden om ordrett gjengivelse er falsifiserbar, og den er falsifisert.
//
// Et *hull* i forankringen er noe annet enn et avvik. Da har kontrolløren
// ingen venstreside å bedømme det feltet mot, og raden kan ikke bekreftes —
// verken av maskinen eller av et menneske. Utfallet blir uncertain, og
// beskjeden sier at funnet må ekstraheres på nytt framfor at noen skal lete
// fram grunnlaget selv (ANTIDEP_CONSTITUTION.md §6, §8, §11).
//
// ----------------------------------------------------------------------------
// Hva `source_locator` betyr her
//
// Kildepekeren er fritekst («Sammendrag (MEDLINE-post)»), og hvilken del av et
// dokument den peker på, kan ikke avgjøres maskinelt. Feltet føres derfor opp
// som kontrollert bare når to ting holder samtidig: representasjonen pekeren
// peker inn i er hentet på nytt og har samme fingeravtrykk som den registrerte,
// **og** sitatet er funnet ordrett i nettopp den representasjonen. Da er
// pekeren korroborert så langt en maskin kan komme: teksten den peker på finnes,
// i den utgaven den ble lest fra.
//
// Uten sitat er det ingenting å korroborere pekeren med, og feltet føres ikke
// opp — som igjen gjør `verified` umulig, fordi
// `evidence_verifications_locator_checked_check` krever nettopp det feltet.
// Regelen i basen og regelen her peker altså samme vei, uten at den ene stoler
// på den andre.
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// `sourceText` er hentet fra internett og er data, aldri instruksjoner
// (CLAUDE.md). Den brukes bare som høystakk for søk, og ingenting i den kan
// endre hva kontrollen gjør.
// ============================================================================

import type { VerificationExtraction, VerificationItem } from './verification-input.ts'

/** Verdiene `workflow.evidence_check_field` tillater (migrasjon 005). */
export type EvidenceCheckField =
  | 'population'
  | 'sample_size'
  | 'intervention_arm'
  | 'comparator_arm'
  | 'outcome'
  | 'timepoint'
  | 'reported_direction'
  | 'effect_measure'
  | 'estimate'
  | 'confidence_interval'
  | 'availability_semantics'
  | 'source_wide_absence'
  | 'limitations'
  | 'source_locator'
  | 'raw_extraction'

/**
 * Feltene denne kontrollen kan bedømme.
 *
 * Den er en **delkontroll**, og det er ikke en mangel som skal skjules: den
 * leser ordrette utdrag og tall, og har ingen måte å avgjøre om tidspunktet er
 * 8 eller 12 uker, om effektmålet er riktig valgt, om retningen er riktig
 * tolket, om et felt med rette står som «ikke rapportert», eller om
 * forbeholdene er dekkende. `checked_fields` sier derfor alltid nøyaktig hva
 * kontrollen gikk gjennom (DATABASE_ARCHITECTURE.md §29).
 *
 * Publiseringsgaten leser det samme vokabularet: `verified` fra denne
 * kontrollen betyr «alt jeg kontrollerte, stemte», ikke «ekstraksjonen er
 * kontrollert», og gatens G5b krever at kontrollene *til sammen* dekker det
 * raden påstår noe om (migrasjon 20260907093000). Listen her er den ene siden
 * av den kontrakten, og er prøvd mot den andre.
 */
export const CHECKABLE_FIELDS = [
  'raw_extraction',
  'source_locator',
  'source_wide_absence',
  'intervention_arm',
  'outcome',
  'comparator_arm',
  'population',
  'sample_size',
  'estimate',
  'confidence_interval',
] as const satisfies readonly EvidenceCheckField[]

/** Verdiene `workflow.verification_outcome` tillater (migrasjon 005). */
export type VerificationOutcome = 'verified' | 'needs_correction' | 'rejected' | 'uncertain'

export interface ExtractionCheckReport {
  readonly outcome: VerificationOutcome
  readonly checkedFields: readonly EvidenceCheckField[]
  /** Avvikene kontrollen fant. `null` bare når den ikke fant noen. */
  readonly findings: string | null
  /** Hvordan kontrollen ble gjennomført, og hva den ikke kunne avgjøre. */
  readonly rationale: string
}

/** Grunnlaget kontrollen fikk: den registrerte raden, og kilden hentet på nytt. */
export interface ExtractionCheckContext {
  readonly item: VerificationItem
  /** Representasjonen slik den er nå, dekodet som tekst. */
  readonly sourceText: string
  /** Om den hentede representasjonen har samme fingeravtrykk som den registrerte. */
  readonly representationReproduced: boolean
}

// ----------------------------------------------------------------------------
// Normalisering av høystakken
//
// To projeksjoner av samme tekst, og et treff i én av dem teller. Grunnen er at
// et sitat kopiert fra en lesbar visning ofte krysser markup i råsvaret: i en
// MEDLINE-post ligger sammendraget inne i `<AbstractText>`-elementer, og et
// sitat over to avsnitt ville aldri matchet råteksten. Å bare søke i den
// taggfrie ville derimot mistet treff i rene tekstkilder med spisse
// parenteser i seg. Begge finnes derfor, og ingen av dem endrer hva som er
// registrert — de er søkeprojeksjoner, ikke data.
// ----------------------------------------------------------------------------

const XML_ENTITIES: Readonly<Record<string, string>> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
}

/**
 * Ett kodepunkt fra en numerisk entitet, eller `null` når det ikke finnes noe.
 *
 * `String.fromCodePoint` kaster `RangeError` på alt over U+10FFFF, og
 * `&#x110000;` er fullt lovlig å skrive i en fil. Kildeinnhold er utrygg
 * ekstern data (CLAUDE.md), så avkodingen må være total: én slik sekvens i én
 * kilde skal ikke kunne stoppe kontrollen av resten av køen. En ugyldig
 * entitet beholdes ordrett framfor å bli til noe annet — vi vet ikke hva den
 * var ment å være, og en gjetning ville endret teksten kontrollen søker i.
 */
function codePointFrom(digits: string, radix: number): string | null {
  const code = Number.parseInt(digits, radix)
  if (!Number.isInteger(code) || code < 0 || code > 0x10ffff) {
    return null
  }
  return String.fromCodePoint(code)
}

function decodeEntities(text: string): string {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (match, body: string) => {
    if (body.startsWith('#x') || body.startsWith('#X')) {
      return codePointFrom(body.slice(2), 16) ?? match
    }
    if (body.startsWith('#')) {
      return codePointFrom(body.slice(1), 10) ?? match
    }
    return XML_ENTITIES[body.toLowerCase()] ?? match
  })
}

/**
 * Gjør tekst sammenlignbar uten å endre hva den sier: Unicode-normalisert,
 * små bokstaver, typografiske anførselstegn og bindestreker gjort like, og alt
 * blanktegn slått sammen. Ordene og tallene er de samme.
 */
function normalize(text: string): string {
  return text
    .normalize('NFC')
    .replaceAll(/[‘’‛′]/g, "'")
    .replaceAll(/[“”‟″]/g, '"')
    .replaceAll(/[‐-―−]/g, '-')
    .replaceAll(/\s+/g, ' ')
    .toLowerCase()
    .trim()
}

function stripTags(text: string): string {
  return text.replaceAll(/<[^>]*>/g, ' ')
}

/**
 * Setningene i en tekst.
 *
 * Deler på punktum, semikolon, utropstegn og spørsmålstegn — ikke på kolon,
 * fordi et konfidensintervall skrives «CI 95%: 0,4 til 2,6» og ville blitt delt
 * i to, og ikke på komma, fordi et komma sjelden skiller to påstander om
 * forskjellige armer. Et punktum mellom to sifre er et desimalskilletegn og
 * deler ingenting.
 */
function sentences(text: string): readonly string[] {
  return (
    text
      // Semikolon, utrops- og spørsmålstegn deler alltid. Et punktum deler også,
      // med ett unntak: står det mellom to sifre, er det et desimalskilletegn.
      // Den forrige regelen krevde at *ingen* av sidene var et siffer, og lot
      // derfor «… N = 48. Sertraline …» bli én setning.
      .split(/[;!?]|(?<!\d)\.|\.(?!\d)/u)
      .map((part) => part.trim())
      .filter((part) => part.length > 0)
  )
}

/** De to høystakkene et søk gjøres mot. */
export function searchProjections(sourceText: string): readonly string[] {
  const raw = normalize(decodeEntities(sourceText))
  const withoutTags = normalize(decodeEntities(stripTags(sourceText)))
  return raw === withoutTags ? [raw] : [raw, withoutTags]
}

/**
 * Ordrett forekomst. Brukes på sitater, som er lange og entydige i seg selv.
 *
 * Eksportert fordi claim-kontrollen (`claim-checks.ts`) stiller nøyaktig det
 * samme spørsmålet om de samme utdragene: står det ekstraksjonen sier den siterte,
 * fortsatt i representasjonen? To implementasjoner av det spørsmålet ville kunnet
 * svare forskjellig på den samme kilden.
 */
export function verbatimOccursIn(projections: readonly string[], needle: string): boolean {
  const wanted = normalize(needle)
  if (wanted.length === 0) {
    return false
  }
  return projections.some((haystack) => haystack.includes(wanted))
}

/** Et tegn som hører til et ord. Grensen mellom to ord er fraværet av ett slikt. */
const WORD_CHARACTER = /[\p{L}\p{N}]/u

/**
 * Ordrett forekomst som *begynner og slutter mellom ord*.
 *
 * Forskjellen fra `verbatimOccursIn` er ikke akademisk. Dette slapp gjennom i
 * produksjon som kildeforankringen for behandlingsarmene i Fava 2000:
 *
 *   «tine (N = 92), sertraline, (N = 96), or paroxetine»
 *
 * Utdraget står ordrett i artikkelen — men det begynner inne i «fluoxetine», og
 * en kontrollør som leser det, ser ikke engang hvilket virkestoff de 92 gjelder.
 * Et utdrag som starter midt i et ord, er ikke et utdrag av en setning; det er
 * et utsnitt av en tegnstrøm.
 *
 * Kontrollen er deterministisk og robust fordi den ikke tolker språk i det hele
 * tatt: den ser på tegnet rett foran og rett bak treffet i den teksten utdraget
 * faktisk er hentet fra. Den kan derfor ikke ta feil av en forkortelse, et
 * linjeskift fra en PDF eller en tabell — den vet ikke hva en setning er.
 *
 * Står utdraget flere steder, holder det at **én** forekomst står mellom
 * ordgrenser: da finnes det en lesning der utdraget er hele ord.
 */
export function verbatimOccursWholeWordsIn(
  projections: readonly string[],
  needle: string,
): boolean {
  const wanted = normalize(needle)
  if (wanted.length === 0) {
    return false
  }
  // Begynner utdraget med et skilletegn, kan det ikke kappe et ord i to, og da
  // er det ingen grense å kreve. Samme bak.
  const opensWord = WORD_CHARACTER.test(wanted.slice(0, 1))
  const closesWord = WORD_CHARACTER.test(wanted.slice(-1))
  for (const haystack of projections) {
    for (let at = haystack.indexOf(wanted); at !== -1; at = haystack.indexOf(wanted, at + 1)) {
      const before = at === 0 ? '' : haystack.slice(at - 1, at)
      const after = haystack.slice(at + wanted.length, at + wanted.length + 1)
      const openClean = !opensWord || before === '' || !WORD_CHARACTER.test(before)
      const closeClean = !closesWord || after === '' || !WORD_CHARACTER.test(after)
      if (openClean && closeClean) {
        return true
      }
    }
  }
  return false
}

/**
 * Forekomst av et *begrep* — et legemiddelnavn, et endepunkt — med ordgrense.
 *
 * En delstrengsjekk er farlig i nettopp dette registeret: «citalopram» står
 * inne i «escitalopram», og «venlafaxine» inne i «desvenlafaxine». Et utdrag om
 * escitalopram ville da bundet en citalopramrad, og tallene i det ville blitt
 * kontrollert som om de var citalopramradens. De klinisk viktige forvekslingene
 * er nettopp de prefikserte formene — `es-`, `des-`, `levo-` — så grensen foran
 * begrepet er den som avgjør.
 *
 * Etter begrepet tillates inntil to bokstaver. Katalogen er på norsk og kildene
 * på engelsk, og forskjellen er som regel nettopp en endelse: «sertralin» i
 * katalogen, «sertraline» i kilden. Uten den åpningen ville ingen norsk
 * legemiddeletikett matchet en engelsk kilde. To bokstaver er nok til
 * endelsen og for lite til å nå et annet virkestoffnavn.
 */
function termOccursIn(projections: readonly string[], term: string): boolean {
  const wanted = normalize(term)
  if (wanted.length === 0) {
    return false
  }
  const pattern = new RegExp(
    `(?<![\\p{L}\\p{N}])${escapeRegExp(wanted)}\\p{L}{0,2}(?![\\p{L}\\p{N}])`,
    'u',
  )
  return projections.some((haystack) => pattern.test(haystack))
}

// ----------------------------------------------------------------------------
// Hva som teller som et sitat i `raw_extraction`
//
// Kolonnen er jsonb fordi variasjonen mellom kildetyper er reell (migrasjon
// 003, §20), og formen er ikke én: den manuelle skriveveien lagrer ett sitat
// under `sitat` (migrasjon 007e), mens de seedede funnene bruker `metode`,
// `resultat` og `populasjon`. Kontrollen kan derfor ikke slå opp én nøkkel — den
// må lese den formen den finner.
//
// Hver strengverdi i strukturen behandles som et ordrett utdrag, med ett unntak:
// verdier kortere enn `MIN_QUOTE_LENGTH` hoppes over. Korte verdier i et
// råekstraksjonsobjekt er metadata og ikke utdrag — `"kildespraak": "en"` er
// det tydeligste eksempelet — og å kreve at de står i kilden ville gitt et avvik
// for en opplysning som aldri var ment å stå der. Grensen er satt der et utdrag
// begynner å være noen få ord, og den er en dokumentert avveining, ikke en
// naturlov.
// ----------------------------------------------------------------------------

/** Kortere strengverdier i raw_extraction er metadata, ikke ordrette utdrag. */
export const MIN_QUOTE_LENGTH = 24

export interface VerbatimQuote {
  /** Stien i strukturen, for at et avvik skal kunne navngi hvilket utdrag det gjelder. */
  readonly key: string
  readonly text: string
}

/** Alle ordrette utdrag i en råekstraksjon, uansett hvilken form den har. */
export function verbatimQuotes(raw: unknown, path = ''): readonly VerbatimQuote[] {
  if (typeof raw === 'string') {
    return raw.trim().length >= MIN_QUOTE_LENGTH ? [{ key: path || 'sitat', text: raw }] : []
  }
  if (Array.isArray(raw)) {
    return raw.flatMap((value, index) => verbatimQuotes(value, `${path}[${String(index)}]`))
  }
  if (typeof raw === 'object' && raw !== null) {
    return Object.entries(raw).flatMap(([key, value]) =>
      verbatimQuotes(value, path === '' ? key : `${path}.${key}`),
    )
  }
  return []
}

// ----------------------------------------------------------------------------
// Tall
//
// Et tall fra databasen er `numeric` og kan bære etterfølgende nuller («1.50»)
// som kilden ikke skriver. Sammenligningen er derfor på den korteste formen som
// betyr det samme, og desimalskilletegnet kan være både punktum og komma —
// norske og engelske kilder skriver ulikt, og tallet er det samme.
//
// **Fortegnet er en del av tallet, og det er en klinisk regel og ikke en
// formalitet.** En vektendring på −1,5 kg og en på 1,5 kg peker motsatt vei, og
// en kontroll som fant «1.5» i kilden og godtok et registrert «-1,5», ville
// bekreftet et funn som snur effektretningen. Et negativt tall krever derfor et
// minustegn rett foran seg, og et positivt tall avvises hvis det står med et
// minustegn foran. Skriver kilden retningen med ord framfor med fortegn («a
// decrease of 1.5 kg»), finner kontrollen ingenting — og da er utfallet
// `uncertain`, ikke en bekreftelse. Det er den samme asymmetrien som gjelder
// ellers: bekreftelse teller, fravær konkluderer ikke.
//
// Grensene rundt treffet hindrer tre ting: at «7» matcher inne i «17», at
// «0.7» leses som «7», og at «12» leses ut av «12.5». Et bindestrek-intervall
// («15-60 mg») gir heller ingen treff på «60»: bindestreken kan ikke skilles
// fra et minustegn, og et tvilstilfelle skal ikke bli til en bekreftelse.
// ----------------------------------------------------------------------------

/** «1.50» → «1.5», «12.0» → «12», «120» → «120». Ingen avrunding. */
export function trimNumericText(value: string): string {
  const trimmed = value.trim()
  if (!/^[+-]?\d+\.\d+$/.test(trimmed)) {
    return trimmed
  }
  return trimmed.replace(/0+$/, '').replace(/\.$/, '')
}

function escapeRegExp(value: string): string {
  return value.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

interface NumberPattern {
  /** Sifrene som regex, med desimalskilletegn og etterfølgende nuller åpne. */
  readonly body: string
  readonly isNegative: boolean
}

/** Sifferdelen av et tall som regex, eller `null` når verdien ikke er et tall. */
function numberPattern(value: string): NumberPattern | null {
  const normalized = trimNumericText(value).replace(/^\+/, '')
  if (!/^-?\d+(\.\d+)?$/.test(normalized)) {
    return null
  }
  const digits = normalized.replace('-', '')
  const [integerPart = '', decimalPart] = digits.split('.')
  return {
    // Etterfølgende nuller er samme tall. `trimNumericText` fjerner dem fra den
    // *registrerte* verdien, så «4,0» blir «4» — og uten den valgfrie halen
    // under ville mønsteret `4` blitt avvist av grensen bak seg i en kilde som
    // skriver «4.0». Et registrert tall kunne da aldri gjenfinnes i en kilde
    // som tok med nullene.
    body:
      decimalPart === undefined
        ? `${escapeRegExp(integerPart)}(?:[.,]0+)?`
        : `${escapeRegExp(integerPart)}[.,]${escapeRegExp(decimalPart)}0*`,
    isNegative: normalized.startsWith('-'),
  }
}

// Foran: et negativt tall krever minustegnet, og minustegnet må selv ikke stå
// rett etter et tall — ellers ville «8-12» blitt lest som «-12». Et positivt
// tall avvises når det står med minustegn foran.
//
// `normalize()` har alt gjort typografiske minus- og bindestreker om til ASCII,
// så det er nok å se etter ett tegn her.
function leadingBoundary(isNegative: boolean): string {
  return isNegative ? '(?<![\\d.,])-' : '(?<![\\d.,-])'
}

// Bak: verken et siffer til, et desimalskilletegn med et siffer etter, eller en
// eksponent. Uten det andre ville «12» blitt funnet inne i «12.5»; uten det
// tredje ville «1.5» blitt funnet inne i «1.5e-3», som er 0,0015 og altså et
// helt annet tall. En eksponent hører til tallet, den er ikke tekst etter det.
const TRAILING_BOUNDARY = '(?![\\d]|[.,]\\d|[eE][+-]?\\d)'

/** Om tallet står i teksten som et selvstendig tall, med riktig fortegn. */
export function numberOccursIn(projections: readonly string[], value: string): boolean {
  const number = numberPattern(value)
  if (number === null) {
    return false
  }
  const pattern = new RegExp(
    `${leadingBoundary(number.isNegative)}${number.body}${TRAILING_BOUNDARY}`,
  )
  return projections.some((haystack) => pattern.test(haystack))
}

// ----------------------------------------------------------------------------
// Selve kontrollen
// ----------------------------------------------------------------------------

interface NumericClaim {
  readonly field: EvidenceCheckField
  readonly label: string
  readonly value: string
  /** Uttrykk som navngir feltet, og som tallet må stå inntil. */
  readonly anchorsBefore: readonly string[]
  readonly anchorsAfter: readonly string[]
  /**
   * Begrepene som *alle* må stå i samme sammenhengende treff som tallet.
   *
   * Dette er bindingen mellom verdien og raden. Uten den kan en setning som
   * navngir det raden trenger, likevel tilskrive tallet noe annet:
   * «Sertraline and paroxetine were compared, and body weight change was
   * 5.0 kg in paroxetine patients» navngir både sertralin og endepunktet, og
   * verdien er paroksetinets.
   */
  readonly contextElements: readonly string[]
  /**
   * Om et av begrepene selv navngir det tallet er en verdi *av*.
   *
   * Endepunktet gjør det: i «weight change of 1.5» er det endepunktet som gjør
   * 1,5 til et estimat. Et legemiddelnavn gjør det aldri — det navngir armen,
   * ikke feltet — og da må feltets egne ankere stå i treffet i tillegg.
   */
  readonly contextIsAnchor: boolean
  /** Det kilden må skrive rett etter tallet, som en registrert enhet. */
  readonly valueSuffix: string
  /** Enheter tallet aldri kan bære i denne rollen. */
  readonly forbiddenAfter: readonly string[]
  /** Merker foran tallet som gir det en annen rolle. */
  readonly forbiddenBefore: readonly string[]
  /** Radens *andre* registrerte tallpåstander, som lim. Se `claimExpressions`. */
  readonly glueExtra: readonly string[]
}

interface TermClaim {
  readonly field: EvidenceCheckField
  readonly label: string
  readonly term: string
}

/** En verdi er oppgitt hvis og bare hvis statusen sier at den er det (§19.1). */
function isReported(availability: string): boolean {
  return availability === 'reported_value'
}

/**
 * Radens egne tallpåstander slik kilder skriver dem — «N = 48», «a mean change
 * of 1.5 kg» — til bruk som lim mellom armen og *en annen* av radens verdier.
 *
 * Et tall mellom armen og verdien er nesten alltid radens eget:
 * «Sertraline-treated patients (N = 48) had a mean weight change of 1.5 kg».
 * Uten utvalgsstørrelsen som lim ville denne helt vanlige og korrekte setningen
 * ikke lenger bundet estimatet til armen.
 *
 * Bare radens egne registrerte verdier slipper igjennom, ikke et hvilket som
 * helst tall: et **fremmed** tall mellom armen og verdien er nettopp signalet om
 * at setningen har begynt å snakke om noe annet. Estimatet står alltid med
 * enheten det er registrert med, av samme grunn som ellers.
 */
function sampleSizeExpressions(e: VerificationExtraction): readonly string[] {
  if (!isReported(e.sampleSizeAvailability) || e.sampleSize === null) {
    return []
  }
  const number = numberPattern(String(e.sampleSize))
  return number === null ? [] : [...SAMPLE_SIZE_ANCHORS_BEFORE, number.body]
}

/**
 * Radens egen populasjonsetikett som **påkrevd del**, ikke som lim.
 *
 * Den var lim først, fordi populasjonen presiserer armen og står nesten alltid
 * mellom armen og verdien: «Sertraline-treated patients **with major depressive
 * disorder** had a mean weight change». Som lim var den bare noe som *fikk* stå
 * der — og da kunne radens påstand og tallets påstand komme fra hver sin
 * populasjon:
 *
 *   «Sertraline-treated patients with major depressive disorder had weight change …»
 *   «Sertraline-treated patients had weight change of 5.0 kg … in adolescents.»
 *
 * Den første binder raden, den andre bekreftet tallet, og tallet gjelder
 * uttrykkelig ungdom. En verdi hører til én arm, ett endepunkt, én kontrast og
 * **én populasjon**, så populasjonen er nå en del av tallets egen binding.
 * Kravet gjelder også utvalgsstørrelsen: et «N = 48» fra en undergruppe er ikke
 * radens utvalg.
 */
function populationElements(e: VerificationExtraction): readonly string[] {
  if (e.populationLabel === null || !isReported(e.populationAvailability)) {
    return []
  }
  return [termAnchor(e.populationLabel)]
}

function estimateExpressions(
  e: VerificationExtraction,
  estimate: string | null,
): readonly string[] {
  if (estimate === null) {
    return []
  }
  const number = numberPattern(estimate)
  return number === null ? [] : [...ESTIMATE_ANCHORS, `${number.body}${unitSuffix(e.estimateUnit)}`]
}

function numericClaims(item: VerificationItem): readonly NumericClaim[] {
  const e = item.extraction
  const claims: NumericClaim[] = []

  if (isReported(e.sampleSizeAvailability) && e.sampleSize !== null) {
    claims.push({
      field: 'sample_size',
      label: 'utvalgsstørrelse',
      value: String(e.sampleSize),
      anchorsBefore: SAMPLE_SIZE_ANCHORS_BEFORE,
      anchorsAfter: SAMPLE_SIZE_ANCHORS_AFTER,
      // Et utvalg er et antall personer i én arm, og bindes til armen.
      contextElements: [termAnchor(e.interventionDrugName), ...populationElements(e)],
      // «Sertraline: 48 tablets were dispensed» navngir armen og står inntil
      // et tall, men sier ingenting om at tallet er et antall personer. Kilden
      // må selv si det — «N = 48», «48 patients» — ellers står feltet
      // uavklart. Retningen er valgt: en liste over enheter som *ikke* er
      // personer («tablets», «centres», «sites», …) kan aldri bli komplett,
      // mens uttrykkene som navngir et utvalg, er få og kjente.
      contextIsAnchor: false,
      valueSuffix: '',
      // En utvalgsstørrelse er et antall personer og bærer aldri en måleenhet.
      forbiddenAfter: [...MEASURE_UNITS, ...TIME_UNITS],
      forbiddenBefore: [],
      glueExtra: estimateExpressions(e, isReported(e.estimateAvailability) ? e.estimate : null),
    })
  }
  if (isReported(e.estimateAvailability) && e.estimate !== null) {
    claims.push({
      field: 'estimate',
      label: 'estimat',
      value: e.estimate,
      anchorsBefore: ESTIMATE_ANCHORS,
      anchorsAfter: ESTIMATE_ANCHORS,
      // Et estimat er verdien av ett endepunkt hos én arm. Begge må stå i
      // samme treff som tallet: at setningen nevner armen et sted, er ikke det
      // samme som at det er den armen verdien gjelder.
      contextElements: [
        termAnchor(e.interventionDrugName),
        termAnchor(e.outcomeLabel),
        // Et effektestimat er verdien av *en kontrast*. Er kontrasten
        // registrert, må kilden si den i samme påstand som verdien: ellers kan
        // et tall fra en placebokontrast bekrefte en rad registrert mot et
        // aktivt virkestoff.
        ...comparatorElements(e),
        ...populationElements(e),
      ],
      contextIsAnchor: true,
      valueSuffix: unitSuffix(e.estimateUnit),
      // Et effektestimat er verken et tidspunkt eller et antall personer.
      forbiddenAfter: [...TIME_UNITS, ...PERSON_NOUNS],
      // Et tall rett etter «N =» er en utvalgsstørrelse, uansett hva som
      // kommer etter det.
      forbiddenBefore: ['\\bn\\s*[=:]'],
      glueExtra: sampleSizeExpressions(e),
    })
  }
  // Konfidensintervallet står ikke her: det er én påstand med tre deler, og de
  // tre kan ikke søkes hver for seg. Se `confidenceIntervalCheck`.
  return claims
}

// ----------------------------------------------------------------------------
// Konfidensintervallet: én påstand, ikke tre tall
//
// «0,4 til 2,6 med 95 % konfidens» er én påstand. Søkes de tre tallene hver for
// seg i hele representasjonen, kan de komme fra tre forskjellige steder, og da
// er det ikke intervallet som er bekreftet. Feilen er ikke teoretisk:
//
//   «90 participants were enrolled. The effect was 1.5 kg (95% CI 0.4 to 2.6).»
//
// Et funn registrert med 0,4–2,6 og nivå **90 %** fant alle tre tallene her —
// `90` fra utvalget, `0.4` og `2.6` fra et intervall som er oppgitt med et
// annet nivå. Kilden sier 95 %, raden sier 90 %, og kontrollen sa `verified`.
//
// Å kreve de tre delene i samme *vindu* er ikke nok, og det er den andre
// halvparten av den samme lærdommen:
//
//   «n=90; CI 0.4 to 2.6»
//   «95% CI was not reported; observed values ranged from 0.4 to 2.6.»
//
// I den første er `90` en utvalgsstørrelse og ikke et nivå — kilden sier aldri
// prosent. I den andre sier kilden uttrykkelig at intervallet *ikke* er
// rapportert, og grenseparet hører til noe annet. Begge lå innenfor et vindu,
// og begge ville blitt bekreftet.
//
// Intervallet kontrolleres derfor som **ett sammenhengende uttrykk**: nivået
// som en eksplisitt prosentangivelse, ankeret der kilden navngir intervallet,
// og grenseparet — i en av de rekkefølgene kilder faktisk skriver dem, med bare
// skilletegn og korte bindeord imellom. Mellomrommet mellom delene kan ikke
// inneholde et siffer, og kan ikke være langt. Da finnes det ikke lenger et
// «i nærheten» et annet tall kan smyge seg inn i.
//
// Finner kontrollen ikke et slikt uttrykk, er utfallet `uncertain` og feltet
// føres ikke opp — ikke et avvik. En kilde kan oppgi intervallet i en tabell,
// i en annen enhet eller uten å navngi det, og asymmetrien gjelder her som
// ellers: bekreftelse teller, fravær konkluderer ikke.
// ----------------------------------------------------------------------------

/**
 * Der kilden selv navngir et konfidensintervall.
 *
 * `\bCI\b` er med små bokstaver også, fordi kilder skriver «ci» i tabeller.
 * Et anker som treffer feil er ufarlig: det åpner bare for en kontroll som
 * fortsatt krever nivå *og* begge grenser på rett plass.
 */
const CI_ANCHOR_SOURCE = '\\bCI\\b|\\bC\\.I\\.|confidence intervals?|konfidensintervall\\w*'

/**
 * Det som får stå mellom delene i uttrykket.
 *
 * En **tillatelsesliste**, ikke en lengdegrense. «Kort og uten siffer» er ikke
 * det samme som «nøytralt»: «was not» og «, not» er begge korte og sifferfrie,
 * og begge snur betydningen av det som følger.
 *
 *   «95% CI was not 0.4 to 2.6»   ← kilden sier at dette *ikke* er intervallet
 *   «95% CI, not 0.4 to 2.6»      ← samme
 *
 * Limet er derfor bare skilletegn, mellomrom, en gjentakelse av selve
 * intervallnavnet («… interval (CI) …»), og en kort liste nøytrale koblingsord
 * som ikke kan bære en benektelse. Et ord som ikke står på listen — `not`,
 * `except`, `unlike`, `ikke` — bryter uttrykket, og det er meningen. Punktum
 * er heller ikke lim: en setningsgrense er ikke en forbindelse.
 *
 * Listen er bevisst kort. Et uttrykk kontrollen ikke kjenner igjen, gir
 * `uncertain` og ikke et avvik, så en manglende form koster en uavklart
 * kontroll — ikke en falsk bekreftelse. Den veien er den trygge.
 */
const CI_GLUE_WORDS = [
  // Nøytrale substantiv og enheter. De bærer ingen betydning som kan snu et
  // tall, men står nesten alltid mellom armen og verdien: «sertraline
  // patients (N = 284)», «a change of 1.5 kg (95% CI …)».
  'patients?',
  'participants?',
  'subjects?',
  'adults?',
  'individuals?',
  'treated',
  'arms?',
  'groups?',
  'pasienter',
  'deltakere',
  'personer',
  'gruppen?',
  'kg',
  'mg',
  'g',
  'points?',
  'poeng',
  // Artikler, hjelpeverb og statistikkord. Nøytrale i seg selv, og de står
  // nesten alltid mellom begrepet og verdien: «a mean gain of 0.8 kg».
  'an?',
  'en',
  'et',
  'had',
  'have',
  'has',
  'hadde',
  'har',
  'mean',
  'median',
  'average',
  'gjennomsnittlig',
  'in',
  'i',
  'til',
  'of',
  'was',
  'were',
  'is',
  'are',
  'at',
  'for',
  // `and`/`og` står ikke her, av samme grunn som `while` og `not`: de føyer en
  // ny påstand til, og et intervall fra forrige endepunkt skal ikke kunne
  // kobles til det neste gjennom dem.
  'the',
  'with',
  'var',
  'er',
  'med',
  'fra',
  'på',
] as const

/** Skilletegnene som får være lim. Ingen bokstaver, og ikke punktum. */
const GLUE_PUNCTUATION = '[\\s:;,=()\\[\\]/-]'

/**
 * En limbit som ikke får stumpe av et lengre ord.
 *
 * Limlisten inneholder både `g` og `gjennomsnittlig`. Uten en ordgrense bak
 * treffer `g` den første bokstaven i det lange ordet, og resten — «jennomsnittlig»
 * — er ikke lim: kjeden brytes midt inne i et ord som skulle vært lim.
 *
 * Et mønster med nøstede kvantorer kom seg rundt dette ved å bakspore. Én
 * gjennomgang venstre til høyre gjør ikke det, og skal ikke gjøre det: en
 * limbit som slutter midt i et ord, er ikke den limbiten.
 *
 * Skilletegn og former som slutter på et skilletegn (`\bn\s*[=:]` foran et
 * tall) unntas — der ville en ordgrense vært feil.
 */
function endsInPunctuation(source: string): boolean {
  return source.endsWith(']')
}

/**
 * Hvor langt limet rekker.
 *
 * Inne i ett uttrykk — mellom ankeret og tallet, eller mellom delene i et
 * konfidensintervall — er avstanden kort. Mellom armen og verdien er den ikke:
 * armen er setningens subjekt, og utvalgsstørrelsen står gjerne imellom
 * («Sertraline-treated patients (N = 48) had a mean weight change of 1.5 kg»).
 *
 * Rekkevidden er den svakeste av de to grensene, og det er med vilje: det som
 * faktisk stopper en gal binding, er at limet er en **tillatelsesliste**. Et
 * ord som ikke står på den, bryter kjeden — og et annet legemiddelnavn er
 * alltid et slikt ord. «Sertraline and paroxetine were compared, and body
 * weight change was 5.0 kg … in paroxetine patients» stoppes derfor av `and`
 * og av `paroxetine`, ikke av en avstand.
 */
const GLUE_REACH = 12
const BINDING_REACH = 24

/** Lim, eventuelt med ekstra former som er nøytrale for nettopp dette uttrykket. */
function glue(extra: readonly string[] = [], reach: number = GLUE_REACH): string {
  return `(?:${glueAlternatives(extra).join('|')}){0,${String(reach)}}`
}

/**
 * Limbitene, i den formen både mønstrene og skanneren bruker.
 *
 * Ordgrensen deles av alle de ordlignende formene framfor å stå på hver av dem.
 * Det er ikke bare kortere: én alternasjon med ett blikk framover er vesentlig
 * billigere enn seksti grupper med hvert sitt, og dette mønsteret kjøres i en
 * kvantor på hver posisjon i teksten.
 */
function glueAlternatives(extra: readonly string[]): readonly string[] {
  const all = [...extra, ...CI_GLUE_WORDS]
  const wordLike = all.filter((source) => !endsInPunctuation(source))
  return [
    GLUE_PUNCTUATION,
    ...all.filter(endsInPunctuation),
    ...(wordLike.length === 0 ? [] : [`(?:${wordLike.join('|')})(?![\\p{L}\\p{N}])`]),
  ]
}

const CI_GLUE = glue([CI_ANCHOR_SOURCE])

// ----------------------------------------------------------------------------
// Skalarene: et tall må stå der kilden snakker om det feltet
//
// Samme lærdom som for konfidensintervallet, én gang til. `numberOccursIn` sier
// bare at *sifferrekken* finnes et sted i representasjonen, og det er ikke det
// samme som at kilden oppgir den verdien for det feltet:
//
//   registrert `sample_size = 90`, kilden sier «90% improved»
//   registrert `estimate = 15`,    kilden sier «15 mg once daily»
//
// I begge tilfellene fantes tallet, og i ingen av dem oppga kilden verdien.
// Feltet ble likevel ført opp som kontrollert, og raden kunne bli `verified`.
// `checked_fields` skal si hva kontrollen faktisk gikk gjennom
// (DATABASE_ARCHITECTURE.md §29), og «samme siffer et annet sted» er ikke det.
//
// Tallet må derfor stå inntil et uttrykk som navngir feltet — «N = 48»,
// «284 adults», «mean weight gain of 0.8» — med det samme nøytrale limet som
// ellers. Ordlistene under er korte med vilje, og retningen på feilen er valgt:
// en formulering listen ikke kjenner igjen gir `uncertain`, altså en uavklart
// kontroll, ikke en falsk bekreftelse. Å utvide en liste er trygt; å la et
// nakent tall telle er det ikke.
//
// Enheten alene er ikke et anker for estimatet. «15 mg» navngir en dose, ikke
// et effektestimat, og et felt som ble kontrollert mot en dose ville vært
// nøyaktig den feilen dette skal hindre.
// ----------------------------------------------------------------------------

/**
 * Uttrykk som *navngir* utvalgsstørrelsen, og som derfor kan stå foran tallet.
 *
 * Bare navngivende former. Verb som `included`, `enrolled` og `completed` sto
 * her først, og det var galt: de sier hva som ble gjort, ikke hva som telles.
 * «Participants completed 12 weeks of treatment» bekreftet et registrert
 * `sample_size = 12`, der `12` er en varighet.
 *
 * De virkelige formene de skulle dekke — «enrolled 48 patients», «a total of
 * 284 adults» — er allerede dekket av deltakerordene under, som binder tallet
 * til antall personer. Verbene ga altså ingen dekning, bare en åpning.
 *
 * `n` krever `=` eller `:` rett etter: «N = 48» navngir utvalget, en løs `n`
 * i nærheten av et tall gjør det ikke.
 */
const SAMPLE_SIZE_ANCHORS_BEFORE = ['\\bn\\s*[=:]', 'sample sizes?', 'utvalgsstørrelse\\w*']

const SAMPLE_SIZE_ANCHORS_AFTER = [
  'patients?',
  'participants?',
  'subjects?',
  'adults?',
  'individuals?',
  'volunteers?',
  'women',
  'men',
  'cases?',
  'controls?',
  'pasienter',
  'deltakere',
  'personer',
  'forsøkspersoner',
  'kvinner',
  'menn',
]

/**
 * Uttrykk som navngir et effektestimat. Enheten alene teller ikke.
 *
 * `mean`, `median`, `average` og `gjennomsnitt` står bevisst *ikke* her, av
 * samme grunn som verbene er borte fra utvalgsstørrelsen: de er statistikk over
 * hva som helst, ikke navnet på et effektmål. «The median was 12 months»
 * bekreftet et registrert estimat på 12. Ordene finnes fortsatt i de virkelige
 * formene — «a mean weight **gain** of 0.8», «the mean **difference** was
 * 0.8» — der det er det effektspesifikke ordet som bærer.
 */
const ESTIMATE_ANCHORS = [
  'difference',
  'differences',
  'change',
  'changes',
  'gain',
  'loss',
  'increase',
  'decrease',
  'reduction',
  'estimates?',
  '\\bOR\\b',
  '\\bRR\\b',
  '\\bHR\\b',
  '\\bMD\\b',
  '\\bSMD\\b',
  '\\bWMD\\b',
  'odds ratios?',
  'risk ratios?',
  'hazard ratios?',
  'forskjell\\w*',
  'endring\\w*',
  'økning\\w*',
  'reduksjon\\w*',
  'nedgang\\w*',
  'estimat\\w*',
]

/** Et hvilket som helst tall, til å telle opp kandidater med. */
const ANY_NUMBER = `(?<![\\d.,])(-?\\d+(?:[.,]\\d+)?)${TRAILING_BOUNDARY}`

// ----------------------------------------------------------------------------
// Enheten bak tallet forteller hvilken rolle det har
//
// «body weight change at 5.0 weeks» oppgir et tidspunkt, ikke en effekt.
// «Sertraline 48 mg daily» oppgir en dose, ikke et utvalg. Et generelt
// nærhetsmønster ser ingen forskjell: begge står inntil det bindende begrepet,
// med lim imellom som i seg selv er nøytralt.
//
// Enheten gjør forskjellen, og den er avlesbar. En utvalgsstørrelse er et
// antall personer og står aldri med en måleenhet etter seg; et effektestimat
// er ikke et tidspunkt og ikke et antall personer. Tall med feil enhet bak seg
// er derfor ikke kandidater for feltet.
// ----------------------------------------------------------------------------

const TIME_UNITS = ['weeks?', 'days?', 'months?', 'years?', 'uker?', 'dager?', 'måneder?', 'år']
const MEASURE_UNITS = ['mg', 'kg', 'g', 'ml', 'l', 'mmol', 'mol', 'points?', 'poeng', '%']
const PERSON_NOUNS = [
  'patients?',
  'participants?',
  'subjects?',
  'adults?',
  'pasienter',
  'deltakere',
  'personer',
]

function withoutUnits(units: readonly string[]): string {
  return `(?!\\s*(?:${units.join('|')})(?![\\p{L}\\p{N}]))`
}

/**
 * Et tall i riktig rolle: uten en enhet feltet aldri kan ha, og uten et merke
 * foran seg som gir det en annen rolle.
 *
 * «(N = 48) had a mean weight change of …» er den vanlige formen der begge
 * gjelder: 48 står inntil endepunktet, men `N =` foran sier at det er et
 * utvalg og ikke en effekt.
 */
function numberInRole(
  forbiddenAfter: readonly string[],
  forbiddenBefore: readonly string[],
): string {
  const before = forbiddenBefore.length === 0 ? '' : `(?<!(?:${forbiddenBefore.join('|')})\\s*)`
  return `${before}${ANY_NUMBER}${withoutUnits(forbiddenAfter)}`
}

/** «1,50» og «1.5» er samme tall. Sammenlignes på én form. */
function sameNumber(value: string): string {
  return trimNumericText(value.replace(',', '.')).replace(/^\+/, '')
}

export type AnchoredNumberMatch =
  | { readonly kind: 'confirmed' }
  | { readonly kind: 'missing' }
  /** Flere forskjellige tall er oppgitt for samme felt i utdraget. */
  | { readonly kind: 'ambiguous'; readonly candidates: readonly string[] }

/**
 * Hva utdraget sier om dette feltet: den registrerte verdien, ingenting, eller
 * flere verdier.
 *
 * Rekkefølgen er åpen fordi kilder skriver begge veier: «N = 48» og
 * «284 adults» sier det samme om utvalget.
 *
 * ----------------------------------------------------------------------------
 * Hvorfor flere kandidater ikke er en bekreftelse
 *
 * Et helt vanlig utdrag beskriver flere armer i én setning:
 *
 *   «Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) …»
 *
 * Å søke etter *den registrerte* verdien her ville bekreftet både en riktig og
 * en feilregistrert rad: `48` står der, men det gjør `44` og `47` også, og
 * ingenting i teksten binder maskinelt et av dem til nettopp denne raden.
 * Legemiddelnavnet står riktignok inntil tallet, men det gjør de andre
 * legemidlenes navn også, og en avstandsregel mellom dem ville vært en
 * gjetning forkledd som en kontroll.
 *
 * Kontrollen teller derfor opp *alle* tallene utdraget oppgir for feltet. Er
 * det nøyaktig ett, og det er det registrerte, er raden bekreftet. Er det
 * flere, kan ikke kontrollen avgjøre hvilket som er radens, og feltet står
 * uavklart — ikke som et avvik. Det er samme asymmetri som ellers: en kontroll
 * som ikke kan konkludere, skal ikke leses som en bekreftelse
 * (ANTIDEP_CONSTITUTION.md §6, §11).
 *
 * **Grensen, skrevet ut:** opptellingen ser det samme mønsteret bekreftelsen
 * ser. Skriver kilden den andre armen på en form ankerlisten ikke dekker («a
 * mean decrease *in weight of* 0.4 kg»), ser kontrollen bare én kandidat og
 * bekrefter den. Å telle kandidater med en løsere regel enn den som bekrefter,
 * ble prøvd og forkastet: den fant tall langt unna og gjorde nesten enhver rad
 * uavklart, altså en verifikator som ikke lenger sier noe. Regelen fanger den
 * formen flerarmsstudier oftest bruker — «N = 44; N = 48» og flere
 * intervalluttrykk — og ikke enhver språklig variant.
 */
function collectNumbers(
  projections: readonly string[],
  contextElements: readonly string[],
  valueForms: readonly string[],
  glueExtra: readonly string[],
): Set<string> {
  const candidates = new Set<string>()
  for (const form of valueForms) {
    const elements = [...contextElements, form]
    // `u` er nødvendig: uten den er `\p{L}` i et begrepsanker bokstavene «p{L}»
    // og ikke en bokstavklasse.
    const digits = new RegExp(form, 'iu')
    for (const projection of projections) {
      for (const span of spansWithAllElements(projection, elements, glueExtra)) {
        for (const text of span[contextElements.length] ?? []) {
          const found = digits.exec(text)?.[1]
          if (found !== undefined) {
            candidates.add(sameNumber(found))
          }
        }
      }
    }
  }
  return candidates
}

/**
 * Begrepet som mønster, med de *samme* grensene som `termOccursIn`.
 *
 * Uten grensene var dette igjen en delstrengsjekk: «Citalopram was compared
 * with escitalopram-treated patients (N = 48)» slapp gjennom det ytre filteret
 * på ekte «Citalopram», og nærhetsmønsteret bandt så tallet til delstrengen
 * inne i «escitalopram».
 */
function termAnchor(term: string): string {
  return `(?<![\\p{L}\\p{N}])${escapeRegExp(normalize(term))}\\p{L}{0,2}(?![\\p{L}\\p{N}])`
}

/**
 * Enheten kilden må skrive rett etter tallet.
 *
 * Samme tall i kilogram og i prosent er to forskjellige kliniske påstander, og
 * datamodellen krever derfor en enhet for de dimensjonale effektmålene
 * (`mean_change`, `mean_difference`). Kontrollen kan da bare føre estimatet opp
 * som kontrollert når verdien **og** enheten er gjenfunnet sammen: «a mean
 * weight change of 1.5%» bekrefter ikke en rad registrert som 1,5 kg.
 *
 * Er ingen enhet registrert, er målet dimensjonsløst (OR, RR, HR) og det finnes
 * ingen enhet å kreve.
 *
 * Skriver kilden enheten på en annen form enn den registrerte — «kilograms»
 * mot «kg», «points» mot «poeng» — står feltet uavklart. Det er den trygge
 * retningen: en kontroll som ikke konkluderte, ikke en bekreftelse av en verdi
 * i feil størrelse.
 */
function unitSuffix(unit: string | null): string {
  const normalized = unit === null ? '' : normalize(unit)
  if (normalized === '') {
    return ''
  }
  return `\\s*${escapeRegExp(normalized)}(?![\\p{L}\\p{N}])`
}

/**
 * Hvert sammenhengende treff som inneholder **alle** delene, med det som hver
 * del traff.
 *
 * Rekkefølgen er åpen: kilder skriver «sertraline … weight change … 1.5» og «a
 * weight change of 1.5 in sertraline patients», og begge sier det samme. Kravet
 * om at delene står i *samme* treff er derimot ikke åpent.
 *
 * ----------------------------------------------------------------------------
 * Ett gjennomløp, ikke alle rekkefølger
 *
 * Den opplagte skrivemåten er ett regexmønster per rekkefølge, med lim imellom.
 * Med fem deler er det 120 mønstre, hvert med nøstede kvantorer — og på en tekst
 * som *ikke* passer, prøver motoren alle måter å dele limet på. Målt: over 20
 * sekunder på ett enkelt funn. Kildeteksten er utrygg ekstern data
 * (ANTIDEP_CONSTITUTION §3.8 / EVIDENCE_PIPELINE §3.8), så kjøretiden kan ikke
 * avhenge av at den er snill.
 *
 * I stedet skannes teksten én gang venstre til høyre etter deler *og* lim. Et
 * sammenhengende treff er en ubrutt rekke av slike: første tegn som verken er en
 * del eller lim, bryter rekken — og det er nettopp det tillatelseslisten skal
 * gjøre. Rekkevidden håndheves som før, som en øvre grense på hvor mange
 * limbiter som får stå mellom to deler.
 */
function spansWithAllElements(
  projection: string,
  elements: readonly string[],
  glueExtra: readonly string[],
): readonly (readonly string[][])[] {
  const glueSource = glueAlternatives(glueExtra).join('|')
  // Delene står først i alternasjonen: der en del og en limbit begynner på samme
  // sted, er det delen som gjelder.
  const scanner = new RegExp(
    `${elements.map((element, index) => `(?<x${String(index)}>${element})`).join('|')}|(?:${glueSource})`,
    'giu',
  )

  const spans: (readonly string[][])[] = []
  let found = new Map<number, string[]>()
  let glueRun = 0
  let end = -1

  const close = () => {
    if (found.size === elements.length) {
      spans.push(elements.map((_, index) => found.get(index) ?? []))
    }
    found = new Map()
    glueRun = 0
  }

  for (const match of projection.matchAll(scanner)) {
    if (match.index !== end) {
      close()
    }
    end = match.index + match[0].length
    const hit = Object.entries(match.groups ?? {}).find(([, value]) => value !== undefined)
    if (hit === undefined) {
      glueRun += 1
      if (glueRun > BINDING_REACH) {
        close()
      }
      continue
    }
    glueRun = 0
    const index = Number(hit[0].slice(1))
    found.set(index, [...(found.get(index) ?? []), hit[1] ?? ''])
  }
  close()
  return spans
}

/** Om alle delene står i ett sammenhengende treff et sted i projeksjonene. */
function boundTogether(
  projections: readonly string[],
  elements: readonly string[],
  glueExtra: readonly string[],
): boolean {
  return projections.some(
    (projection) => spansWithAllElements(projection, elements, glueExtra).length > 0,
  )
}

function anchoredNumberMatch(
  projections: readonly string[],
  claim: NumericClaim,
): AnchoredNumberMatch {
  // **Ett sammenhengende treff**, ikke to som tilfeldigvis gir samme tall.
  //
  // Å skjære sammen mengder av tallverdier var ikke en binding: to forskjellige
  // forekomster kunne dekke hver sin halvdel. «Sertraline 48 mg daily was
  // used» ga 48 fra armnærheten, «Sertraline was compared with paroxetine
  // patients (N = 48)» ga 48 fra feltankeret, og snittet ble {48} — uten at
  // noen ett sted sa at sertralinarmen hadde 48 deltakere.
  //
  // Mønsteret krever derfor at **alle** de bindende begrepene, feltets anker og
  // tallet står i *samme* treff, i en hvilken som helst rekkefølge. Begrepene
  // er ikke alternativer til hverandre og ikke alternativer til ankeret: et
  // legemiddelnavn ved siden av et tall er ikke en utvalgsstørrelse, og en
  // setning som nevner armen et sted, tilskriver ikke verdien den armen.
  const number = `${numberInRole(claim.forbiddenAfter, claim.forbiddenBefore)}${claim.valueSuffix}`
  const g = glue([...claim.anchorsBefore, ...claim.anchorsAfter])
  // Limet mellom begrepene og verdien rekker lenger enn limet inne i uttrykket,
  // og slipper i tillegg igjennom radens egne andre tallpåstander. Se
  // `BINDING_REACH` og `sampleSizeExpressions`.
  const bindingGlue = [...claim.anchorsBefore, ...claim.anchorsAfter, ...claim.glueExtra]

  // Formene tallet kan ha inne i treffet: navngitt av feltets eget anker, eller
  // — når et av begrepene selv navngir feltet — av begrepet ved siden av.
  const valueForms: string[] = []
  if (claim.contextIsAnchor) {
    valueForms.push(number)
  }
  if (claim.anchorsBefore.length > 0) {
    valueForms.push(`(?:${claim.anchorsBefore.join('|')})${g}${number}`)
  }
  if (claim.anchorsAfter.length > 0) {
    valueForms.push(`${number}${g}(?:${claim.anchorsAfter.join('|')})`)
  }

  const candidates = collectNumbers(projections, claim.contextElements, valueForms, bindingGlue)
  if (candidates.size === 0) {
    return { kind: 'missing' }
  }
  if (candidates.size > 1) {
    return { kind: 'ambiguous', candidates: [...candidates].sort() }
  }
  return candidates.has(sameNumber(claim.value)) ? { kind: 'confirmed' } : { kind: 'missing' }
}

/**
 * Nivået må være en eksplisitt prosentangivelse.
 *
 * Et nakent tall ved ankeret er ikke et nivå: i «n=90; CI 0.4 to 2.6» er `90`
 * en utvalgsstørrelse. Kilden må selv si prosent.
 */
function levelPattern(value: string): string | null {
  const number = numberPattern(value)
  if (number === null) {
    return null
  }
  return (
    `${leadingBoundary(number.isNegative)}${number.body}${TRAILING_BOUNDARY}` +
    '\\s*(?:%|percent|pct|prosent)'
  )
}

// Det som skiller de to grensene i et intervall. Inne i et navngitt
// konfidensintervall er en bindestrek intervallets strek og ikke et minustegn —
// «95% CI 0.4-2.6» er den vanligste skrivemåten i MEDLINE-sammendrag. Utenfor
// et slikt anker gjelder fortsatt den strengere regelen i `numberOccursIn`,
// der en bindestrek ikke kan skilles fra et fortegn.
const CI_RANGE_SEPARATOR = '\\s*(?:to|til|and|og|[,;-])\\s*'

/**
 * De to grensene som ett intervall.
 *
 * Dette er forskjellen fra to uavhengige tallsøk: «0,4 til 1,9 … 1,1 til 2,6»
 * inneholder både 0,4 og 2,6, men ingen av intervallene er 0,4–2,6. Bare en
 * sammenhengende skrivemåte teller.
 */
function boundsPattern(lower: string, upper: string): string | null {
  const low = numberPattern(lower)
  const high = numberPattern(upper)
  if (low === null || high === null) {
    return null
  }
  // Etter separatoren er en bindestrek separatoren selv. Et negativt
  // *øvre* tall trenger derfor sitt eget minustegn i tillegg.
  return (
    `${leadingBoundary(low.isNegative)}${low.body}${CI_RANGE_SEPARATOR}` +
    `${high.isNegative ? '-' : ''}${high.body}${TRAILING_BOUNDARY}`
  )
}

/** Om de to grensene står i teksten som ett intervall. */
export function boundsPairOccursIn(text: string, lower: string, upper: string): boolean {
  const pattern = boundsPattern(lower, upper)
  return pattern !== null && new RegExp(pattern).test(text)
}

/** Det registrerte intervallet, slik det skal gjenfinnes. */
export interface ConfidenceInterval {
  readonly lower: string
  readonly upper: string
  readonly levelPercent: string
}

export interface ConfidenceIntervalReport {
  readonly confirmed: boolean
  /** Delene som ikke ble gjenfunnet på rett plass, som «konfidensnivå (90)». */
  readonly unmatched: readonly string[]
  /** Sant når kilden ikke navngir et konfidensintervall i det hele tatt. */
  readonly noAnchor: boolean
  /** Utdraget oppgir flere intervaller, og ingen av dem er entydig radens. */
  readonly ambiguous: readonly string[]
}

/**
 * De rekkefølgene et konfidensintervall faktisk skrives i.
 *
 * Fire, og ikke flere: nivået foran eller bak ankeret, og grensene foran eller
 * bak begge. Alt annet er ikke en skrivemåte, det er tre deler som tilfeldigvis
 * står i nærheten av hverandre.
 */
/**
 * Uttrykket med armen og endepunktet i samme treff, i en hvilken som helst
 * rekkefølge.
 *
 * Begge kreves, av hver sin grunn. Uten endepunktet kunne et intervall som
 * tilhører et annet endepunkt i samme setning bekrefte raden: «a mean HAM-D
 * change of 5.0 points (95% CI 4.0 to 6.0), while body weight change was also
 * recorded» navngir endepunktet, men intervallet er HAM-D-ens. Uten armen
 * kunne et intervall som setningen uttrykkelig tilskriver en annen arm gjøre
 * det samme: «Sertraline and paroxetine were compared, and body weight change
 * was 5.0 kg (95% CI 4.0 to 6.0) in paroxetine patients».
 *
 * Limet slipper igjennom radens eget estimat — intervallet hører til det — men
 * bare med enheten estimatet er registrert med. Ellers kunne en prosentverdi
 * limt et intervall til en rad registrert i kilogram.
 */
function withTerms(
  projections: readonly string[],
  order: string,
  contextElements: readonly string[],
  glueExtra: readonly string[],
): boolean {
  return boundTogether(projections, [...contextElements, order], [CI_ANCHOR_SOURCE, ...glueExtra])
}

function intervalOrders(level: string, bounds: string): readonly string[] {
  const anchor = `(?:${CI_ANCHOR_SOURCE})`
  const g = CI_GLUE
  return [
    // «95% CI 0.4 to 2.6», «95 % konfidensintervall 0,4 til 2,6»
    `${level}${g}${anchor}${g}${bounds}`,
    // «CI 95%: 0.4 to 2.6»
    `${anchor}${g}${level}${g}${bounds}`,
    // «0.4 to 2.6 (95% CI)»
    `${bounds}${g}${level}${g}${anchor}`,
    // «0.4 to 2.6 (CI 95%)»
    `${bounds}${g}${anchor}${g}${level}`,
  ]
}

/**
 * Om et fragment binder begrepene til *hverandre*, ikke bare inneholder dem.
 *
 * Å lete etter hvert begrep for seg er ikke en binding, på nøyaktig samme måte
 * som å lete etter hvert tall for seg ikke er det. To ordrette og sanne utdrag
 * kan da sys sammen til én gal rad:
 *
 *   «Sertraline-treated patients discontinued treatment because of nausea.»
 *   «Paroxetine-treated patients had a mean body weight change over the trial.»
 *
 * Begge står i kilden, sertralin finnes, endepunktet finnes — og ingen del av
 * kilden sier at vektendringen gjelder sertralin. Å kreve dem i samme *utdrag*
 * er heller ikke nok: ett utdrag kan beskrive flere armer, og ren forekomst
 * skiller ikke en positiv binding fra en benektelse («No participants received
 * sertraline; paroxetine-treated patients had …»).
 *
 * Bindingen er derfor den samme som for tallene: begge begrepene i ett
 * sammenhengende treff, med bare kjent lim imellom. `not`, `and` og et fremmed
 * legemiddelnavn er alle ord limet ikke kjenner, og bryter kjeden.
 */

function confidenceIntervalBound(
  projections: readonly string[],
  interval: ConfidenceInterval,
  contextElements: readonly string[],
  glueExtra: readonly string[],
): boolean {
  const level = levelPattern(interval.levelPercent)
  const bounds = boundsPattern(interval.lower, interval.upper)
  if (level === null || bounds === null) {
    return false
  }
  return intervalOrders(level, bounds).some((order) =>
    withTerms(projections, order, contextElements, glueExtra),
  )
}

/**
 * Alle konfidensintervallene utdraget faktisk oppgir, som «0.4|2.6|95».
 *
 * Samme grunn som for skalarene: et utdrag kan oppgi intervaller for flere
 * utfall eller flere armer, og da binder ingenting maskinelt ett av dem til
 * denne raden. Kandidatene telles derfor opp, framfor å lete etter den ene
 * verdien raden oppgir.
 */
function confidenceIntervalCandidates(projections: readonly string[]): readonly string[] {
  const anyLevel = `${ANY_NUMBER}\\s*(?:%|percent|pct|prosent)`
  const anyBounds = `${ANY_NUMBER}${CI_RANGE_SEPARATOR}${ANY_NUMBER}`
  const found = new Set<string>()

  for (const order of intervalOrders(anyLevel, anyBounds)) {
    // Gruppene kommer i den rekkefølgen delene står i mønsteret, så hvilken
    // som er nivå og hvilke som er grenser, avhenger av rekkefølgen. De sorteres
    // ikke: et intervall er nivå + nedre + øvre uansett hvor de står skrevet.
    const levelFirst = order.indexOf(anyLevel) < order.indexOf(anyBounds)
    for (const projection of projections) {
      for (const hit of projection.matchAll(new RegExp(order, 'giu'))) {
        const [, a, b, c] = hit
        if (a === undefined || b === undefined || c === undefined) {
          continue
        }
        const [level, lower, upper] = levelFirst ? [a, b, c] : [c, a, b]
        found.add(`${sameNumber(lower)}|${sameNumber(upper)}|${sameNumber(level)}`)
      }
    }
  }
  return [...found].sort()
}

/**
 * Om representasjonen bekrefter det registrerte konfidensintervallet som ett
 * uttrykk. Kalles bare når intervallet er oppgitt.
 *
 * Bekreftelsen krever at nivå, anker og grensepar står som én sammenhengende
 * skrivemåte. Rapporten sier hvilken del som manglet når den ikke gjør det —
 * og skiller «denne delen finnes ikke noe sted» fra «delene finnes, men ikke i
 * samme uttrykk», fordi de to betyr forskjellige ting for en leser.
 */
export function confidenceIntervalCheck(
  projections: readonly string[],
  interval: ConfidenceInterval,
  /** Armen og endepunktet uttrykket må stå i samme treff som. */
  contextElements: readonly string[],
  /**
   * Radens egne øvrige tallpåstander, som lim — utvalgsstørrelsen, og estimatet
   * når det er bekreftet. De er radens eget, ikke fremmedlegemer.
   */
  glueExtra: readonly string[],
): ConfidenceIntervalReport {
  const candidates = confidenceIntervalCandidates(projections)
  if (candidates.length > 1) {
    return { confirmed: false, unmatched: [], noAnchor: false, ambiguous: candidates }
  }

  if (confidenceIntervalBound(projections, interval, contextElements, glueExtra)) {
    return { confirmed: true, unmatched: [], noAnchor: false, ambiguous: [] }
  }

  const level = levelPattern(interval.levelPercent)
  const levelSeen =
    level !== null && projections.some((projection) => new RegExp(level, 'i').test(projection))
  const boundsSeen = projections.some((projection) =>
    boundsPairOccursIn(projection, interval.lower, interval.upper),
  )
  const anchorSeen = projections.some((projection) =>
    new RegExp(CI_ANCHOR_SOURCE, 'i').test(projection),
  )

  const unmatched: string[] = []
  if (!boundsSeen) {
    unmatched.push(`konfidensgrensene (${interval.lower} til ${interval.upper})`)
  }
  if (!levelSeen) {
    unmatched.push(`konfidensnivå (${interval.levelPercent})`)
  }
  return { confirmed: false, unmatched, noAnchor: !anchorSeen, ambiguous: [] }
}

/** Det registrerte intervallet, eller `null` når raden ikke oppgir noe. */
function reportedConfidenceInterval(item: VerificationItem): ConfidenceInterval | null {
  const e = item.extraction
  // Databasen parer de tre: `ci_lower` er ikke null nøyaktig når intervallet er
  // oppgitt, og `ci_upper` og `ci_level_percent` følger den
  // (evidence_items_confidence_interval_pairing_check,
  // evidence_items_confidence_level_pairing_check). Kontrollen krever likevel
  // alle tre her framfor å stole på at de finnes.
  if (
    !isReported(e.confidenceIntervalAvailability) ||
    e.ciLower === null ||
    e.ciUpper === null ||
    e.ciLevelPercent === null
  ) {
    return null
  }
  return { lower: e.ciLower, upper: e.ciUpper, levelPercent: e.ciLevelPercent }
}

/**
 * Uttrykk der kilden navngir en komparator.
 *
 * Et legemiddelnavn i seg selv sier ingenting om at det *var* komparatoren:
 * «Paroxetine-treated patients discontinued treatment because of nausea» nevner
 * paroksetin uten å si noe om kontrasten i dette funnet. Kilden må selv si det.
 *
 * Listen er kort med vilje, som de andre: en form den ikke kjenner, gir
 * `uncertain` og ikke et avvik.
 */
const COMPARATOR_ANCHORS = [
  'comparators?',
  'compared (?:with|to|against)',
  'comparison',
  'controls?',
  'control (?:group|arm)',
  'versus',
  '\\bvs\\.?',
  'komparator\\w*',
  'kontrollgruppen?',
  'sammenlign\\w*',
]

/**
 * Begrepet kilden må navngi som komparator, eller `null` når funnet er
 * armspesifikt.
 *
 * `placebo` er et begrep på linje med et virkestoffnavn: det står i kilden når
 * kontrasten er placebo, og kan kontrolleres som et hvilket som helst annet
 * begrep. `none` er noe annet — se `termBindings`.
 */
function comparatorTerm(e: VerificationExtraction): string | null {
  if (e.comparatorKind === 'drug') {
    return e.comparatorDrugName
  }
  return e.comparatorKind === 'placebo' ? 'placebo' : null
}

function termClaims(item: VerificationItem): readonly TermClaim[] {
  const e = item.extraction
  const claims: TermClaim[] = [
    { field: 'intervention_arm', label: 'intervensjon', term: e.interventionDrugName },
    { field: 'outcome', label: 'endepunkt', term: e.outcomeLabel },
  ]
  const comparator = comparatorTerm(e)
  if (comparator !== null) {
    claims.push({ field: 'comparator_arm', label: 'komparator', term: comparator })
  }
  if (e.populationLabel !== null && isReported(e.populationAvailability)) {
    claims.push({ field: 'population', label: 'populasjon', term: e.populationLabel })
  }
  return claims
}

/**
 * Bindingene raden må ha i kilden for å være bekreftet.
 *
 * Et ordtreff er ikke støtte for at *denne* raden stemmer. Hver binding krever
 * derfor at delene står i **samme påstand**, med bare kjent lim imellom — og
 * limet er det som tåler benektelser: `not`, `and` og et fremmed legemiddelnavn
 * er alle ord det ikke kjenner.
 *
 * `comparator_kind = none` står bevisst *ikke* her. `none` betyr at **funnet**
 * er armspesifikt, ikke at studien manglet en komparator: vokabularet sier
 * uttrykkelig at «et enarmet gjennomsnitt hentet fra en sammenlignende studie
 * har komparator none» (migrasjon 20260819064500). At kilden sier «Fluoxetine
 * was the comparator» motsier derfor ikke en `none`-rad — det er nettopp den
 * dokumenterte situasjonen. `none` er en påstand om hvordan ekstraksjonen er
 * avgrenset, ikke om kildens tekst, og det finnes ingenting i teksten å
 * kontrollere den mot.
 */
/**
 * Komparatoren som mønsterdeler: navnet, og uttrykket som sier at det *var*
 * komparatoren. Tom når funnet er armspesifikt.
 */
function comparatorElements(e: VerificationExtraction): readonly string[] {
  const comparator = comparatorTerm(e)
  return comparator === null ? [] : [termAnchor(comparator), `(?:${COMPARATOR_ANCHORS.join('|')})`]
}

/**
 * Delene raden består av, som **én** binding.
 *
 * Ikke flere bindinger som holder hver for seg: da kan én rad sys sammen av
 * påstander om forskjellige funn, og hver enkelt binding er sann.
 *
 *   «Sertraline-treated patients had a mean weight change over the trial.»
 *   «Fluoxetine was compared with paroxetine for remission.»
 *
 * Arm og endepunkt er bundet i den første, komparatoren er navngitt som
 * komparator i den andre — og ingen påstand sier at paroksetin er komparator
 * for *dette* funnet. Populasjonen har samme form: «Sertraline-treated adults
 * with major depressive disorder discontinued treatment because of nausea»
 * binder populasjonen til armen, men til et annet utfall.
 *
 * Alle radens aktive deler må derfor stå i **samme sammenhengende treff**.
 * Prisen er skrevet ut andre steder og gjelder her også: et sammendrag som
 * fordeler populasjon, komparator og resultat på hver sin setning, gir
 * `uncertain`. Det er den riktige enden å ta feil i — alternativet er en
 * bekreftelse som bygger på at delene tilfeldigvis stod i samme artikkel.
 */
function rowBindingElements(item: VerificationItem): readonly string[] {
  const e = item.extraction
  return [
    termAnchor(e.interventionDrugName),
    termAnchor(e.outcomeLabel),
    ...comparatorElements(e),
    ...populationElements(e),
  ]
}

/** Hva utdragene måtte ha sagt, skrevet for en leser. */
function rowBindingDescription(item: VerificationItem): string {
  const e = item.extraction
  const parts = [`«${e.interventionDrugName}»`, `«${e.outcomeLabel}»`]
  const comparator = comparatorTerm(e)
  if (comparator !== null) {
    parts.push(`«${comparator}» som komparator`)
  }
  if (e.populationLabel !== null && isReported(e.populationAvailability)) {
    parts.push(`«${e.populationLabel}»`)
  }
  return parts.join(', ')
}

// ----------------------------------------------------------------------------
// Det kildeomfattende søket: den ene halvdelen av et globalt fravær en maskin
// faktisk kan bære
//
// `not_reported` («ikke rapportert i kilden») og `not_measured` («ikke målt i
// studien») er påstander om kilden eller studien SOM HELHET. Et menneske som
// får ett lokalt utdrag, kan avgjøre at verdien mangler *der den ville stått* —
// men ikke at den ikke står noe annet sted (issue #74). Den halvdelen er et
// søk, og et søk er nettopp det en maskin gjør reproduserbart.
//
// ----------------------------------------------------------------------------
// Søket er bevisst bredere enn bekreftelsessøket, og det er ikke en slurv
//
// Resten av denne modulen søker i funnets EGNE utdrag, fordi den skal bekrefte
// at en verdi tilhører nettopp denne raden. Her er påstanden motsatt — at
// ingen slik verdi finnes — og da ville et smalt søk gjort «ikke funnet» til
// et nesten sikkert utfall uansett hva som står i artikkelen. En kontroll som
// alltid sier ja, er ingen kontroll.
//
// Søket går derfor gjennom HELE representasjonen, og krever bare at verdien
// står bundet til funnets behandlingsarm. Endepunktet er med vilje ikke et
// krav: katalogen er norsk og kildene engelske, så «vektendring» står nesten
// aldri i en engelsk artikkel, og et krav om den ville tømt søket for innhold.
//
// ----------------------------------------------------------------------------
// Et treff er ikke et avvik
//
// Finner søket et konfidensintervall bundet til sertralinarmen, vet det ikke om
// intervallet hører til DETTE endepunktet og dette tidspunktet. Treffet er
// derfor ikke en anklage mot ekstraksjonen — det er grunnen til at fraværet
// ikke kan regnes som kontrollert, og teksten navngir hva som ble funnet slik
// at et menneske kan se på det. Samme asymmetri som ellers i modulen: en
// kontroll som ikke kan konkludere, skal aldri leses som en bekreftelse
// (ANTIDEP_CONSTITUTION.md §6, §11).
//
// ----------------------------------------------------------------------------
// Hva «ikke funnet» faktisk betyr, og hvorfor det er nok
//
// Nøyaktig dette: ingen verdi av den arten står i noen passasje som navngir
// armen, noe sted i den kildeversjonen raden viser til.
//
// Det er den påstanden raden faktisk gjør. `not_reported` er i datamodellen
// definert relativt til **kildeversjonen**, ikke til publikasjonen:
// «Statusen gjelder alltid den kildeversjonen og den kildepekeren raden viser
// til, ikke nødvendigvis hele publikasjonen» (kolonnekommentaren på
// `*_availability`, migrasjon 003). Søket kontrollerer derfor nøyaktig den
// påstanden, verken mer eller mindre — og det er grunnen til at et søk kan bære
// den der ett lokalt utdrag ikke kan.
//
// Styrken følger likevel av hva versjonen er: et søk gjennom et abstrakt sier
// mindre om publikasjonen enn et søk gjennom en fulltekst. Begrunnelsen navngir
// derfor representasjonen, slik at dekningen aldri leses som mer enn den er.
//
// To grenser er harde:
//
//   * Representasjonen må ha latt seg reprodusere med det registrerte
//     fingeravtrykket. Ellers gjelder søket en annen tekst enn den raden ble
//     laget av.
//   * Armen må stå i representasjonen. Gjør den ikke det, har søket ingen
//     binding, og «ingen treff» betyr bare at kilden aldri nevner armen —
//     katalogen er norsk og kildene engelske, så det er en helt vanlig
//     tilstand, og nettopp derfor kan den aldri telle som en bekreftelse
//     (DATABASE_ARCHITECTURE.md §29).
// ----------------------------------------------------------------------------

/** Et tall etterfulgt av en tidsenhet: «12 weeks», «8 uker». */
const TIMEPOINT_VALUE = `${ANY_NUMBER}\\s*(?:${TIME_UNITS.join('|')})(?![\\p{L}\\p{N}])`

/**
 * Formene en verdi av hvert felt kan ha i kilden.
 *
 * `null` betyr at feltet ikke har en maskinelt søkbar form, og det er et svar i
 * seg selv: en populasjon er en etikett og ikke et tall, og radens egen etikett
 * er dessuten norsk. Da kan søket verken bekrefte eller avkrefte fraværet, og
 * feltet blir stående udekket framfor å bli stilltiende godkjent.
 */
function absenceValueForms(field: string): readonly string[] | null {
  const sampleSize = numberInRole([...MEASURE_UNITS, ...TIME_UNITS], [])
  const estimate = numberInRole([...TIME_UNITS, ...PERSON_NOUNS], ['\\bn\\s*[=:]'])
  switch (field) {
    case 'sample_size':
      return [
        `(?:${SAMPLE_SIZE_ANCHORS_BEFORE.join('|')})${glue()}${sampleSize}`,
        `${sampleSize}${glue()}(?:${SAMPLE_SIZE_ANCHORS_AFTER.join('|')})`,
      ]
    case 'estimate':
      return [
        `(?:${ESTIMATE_ANCHORS.join('|')})${glue()}${estimate}`,
        `${estimate}${glue()}(?:${ESTIMATE_ANCHORS.join('|')})`,
      ]
    case 'timepoint':
      return [TIMEPOINT_VALUE]
    case 'confidence_interval':
      // Intervallet er ett uttrykk: kilden må navngi det, og det må stå et
      // grensepar ved siden av. To tall i nærheten av hverandre er ikke et
      // intervall, og et anker uten grenser er ikke en verdi.
      return [
        `(?:${CI_ANCHOR_SOURCE})${CI_GLUE}${ANY_NUMBER}${CI_RANGE_SEPARATOR}${ANY_NUMBER}`,
        `${ANY_NUMBER}${CI_RANGE_SEPARATOR}${ANY_NUMBER}${CI_GLUE}(?:${CI_ANCHOR_SOURCE})`,
      ]
    default:
      return null
  }
}

/** Hva søket gjennom hele representasjonen fant for ett felt. */
export type SourceWideAbsenceFinding =
  /** Ingen verdi av den arten står i en passasje som navngir armen. */
  | { readonly kind: 'not_found' }
  /** Noe av den arten står der. Ikke et avvik, men fraværet er ikke kontrollert. */
  | { readonly kind: 'found'; readonly quotes: readonly string[] }
  /** Feltet har ingen maskinelt søkbar form. */
  | { readonly kind: 'not_searchable' }

export interface SourceWideAbsenceReport {
  /** Om hele den kildeomfattende påstanden er kontrollert, for alle feltene. */
  readonly discharged: boolean
  /** Hva søket gjorde, og hvorfor det eventuelt ikke konkluderte. */
  readonly notes: readonly string[]
}

/** Hvor mange treff som navngis i begrunnelsen. Nok til å se på, ikke en dump. */
const QUOTED_CANDIDATES = 3

/**
 * Hva søket faktisk gjennomsøkte, navngitt i begrunnelsen.
 *
 * `not_reported` gjelder per definisjon **den kildeversjonen raden viser til**,
 * ikke nødvendigvis hele publikasjonen (kolonnekommentaren på
 * `knowledge.evidence_items.*_availability`, migrasjon 003). Søket kontrollerer
 * derfor nøyaktig den påstanden — men styrken følger av hva versjonen er, og et
 * søk gjennom et abstrakt sier mindre enn et søk gjennom en fulltekst. Raden
 * navngir den derfor, slik at ingen leser dekningen som mer enn den er
 * (DATABASE_ARCHITECTURE.md §29, EVIDENCE_PIPELINE.md §13).
 */
function representationName(item: VerificationItem): string {
  const representation = item.sourceVersion?.representation ?? null
  return representation === null
    ? 'kildeversjonen, som ikke har en registrert representasjonstype'
    : `kildeversjonen («${representation}»)`
}

/**
 * Passasjene i representasjonen som selv navngir funnets behandlingsarm.
 *
 * Bindingen er **setningen**, ikke limkjeden resten av modulen bruker. Det er
 * et bevisst valg og går motsatt vei av bekreftelseskontrollen: der skal en
 * verdi tilskrives nettopp denne raden, og en streng binding er det som gjør
 * bekreftelsen troverdig. Her er påstanden at ingen slik verdi finnes, og da
 * gjør en streng binding «ikke funnet» til et nesten sikkert utfall uansett hva
 * som står i artikkelen — altså en kontroll som alltid sier ja.
 *
 * Setningen er den bredeste bindingen som fortsatt er en binding, og den er
 * lett å forklare: verdien må stå i en passasje som selv navngir armen.
 */
function armPassages(
  projections: readonly string[],
  interventionDrugName: string,
): readonly string[] {
  return projections
    .flatMap(sentences)
    .filter((fragment) => termOccursIn([fragment], interventionDrugName))
}

/**
 * Søker etter en verdi av feltets art i passasjene som navngir armen.
 *
 * Eksportert for seg fordi den er den ene definisjonen av hva Antidep mener med
 * «ikke funnet i den registrerte kildeversjonen», og fordi den skal kunne
 * prøves uten resten av kontrollen.
 */
export function sourceWideAbsenceSearch(
  armPassageTexts: readonly string[],
  field: string,
): SourceWideAbsenceFinding {
  const forms = absenceValueForms(field)
  if (forms === null) {
    return { kind: 'not_searchable' }
  }
  const quotes = new Set<string>()
  for (const form of forms) {
    const pattern = new RegExp(form, 'giu')
    for (const passage of armPassageTexts) {
      for (const hit of passage.matchAll(pattern)) {
        quotes.add(hit[0].trim().replace(/\s+/g, ' '))
      }
    }
  }
  return quotes.size === 0
    ? { kind: 'not_found' }
    : { kind: 'found', quotes: [...quotes].sort().slice(0, QUOTED_CANDIDATES) }
}

/**
 * Hele den kildeomfattende halvdelen for ett evidensfunn.
 *
 * Alle feltene raden fører som fraværende i kilden må være avklart før feltet
 * kan føres opp: ett udekket felt er en udekket påstand, og en rad som førte
 * det opp likevel, ville påstått større dekning enn operasjonen hadde.
 */
export function sourceWideAbsenceCheck(context: ExtractionCheckContext): SourceWideAbsenceReport {
  const { item, sourceText, representationReproduced } = context
  const fields = item.sourceWideAbsenceFields
  if (fields.length === 0) {
    // Raden gjør ingen kildeomfattende påstand. Da er det ingenting å
    // kontrollere, og gaten krever heller ikke feltet.
    return { discharged: false, notes: [] }
  }
  if (!representationReproduced) {
    return {
      discharged: false,
      notes: [
        'Det kildeomfattende søket ble ikke gjort: representasjonen som ble hentet, har ikke ' +
          'samme fingeravtrykk som den registrerte kildeversjonen, og et søk i den ville ' +
          'gjeldt en annen tekst enn ekstraksjonen ble laget av.',
      ],
    }
  }
  const arm = item.extraction.interventionDrugName
  const passages = armPassages(searchProjections(sourceText), arm)
  if (passages.length === 0) {
    // Uten armen i teksten har søket ingen binding, og «ingen treff» ville
    // bare betydd at kilden aldri nevner den. Katalogen er norsk og kildene
    // engelske, så dette er en helt vanlig tilstand — og nettopp derfor kan
    // den aldri telle som en bekreftelse (ANTIDEP_CONSTITUTION.md §6, §11).
    return {
      discharged: false,
      notes: [
        `Det kildeomfattende søket kunne ikke konkludere: representasjonen navngir ikke ` +
          `«${arm}» noe sted, så det finnes ingen passasje å søke i. Kilden er som regel på ` +
          'engelsk mens katalogen er på norsk, så et manglende treff er ikke et avvik — men ' +
          'det er heller ingen bekreftelse av at opplysningen ikke står der.',
      ],
    }
  }

  const notFound: string[] = []
  const notes: string[] = []
  let discharged = true
  for (const field of fields) {
    const finding = sourceWideAbsenceSearch(passages, field)
    if (finding.kind === 'not_found') {
      notFound.push(field)
      continue
    }
    discharged = false
    if (finding.kind === 'not_searchable') {
      notes.push(
        `Fraværet av «${field}» lar seg ikke søke etter maskinelt: feltet har ingen tallform ` +
          'kontrollen kan gjenkjenne. Feltet er derfor ikke ført opp som kildeomfattende ' +
          'kontrollert.',
      )
      continue
    }
    notes.push(
      `Søket gjennom hele representasjonen fant noe som ligner en verdi for «${field}» i en ` +
        `passasje som navngir ${arm}: ${finding.quotes
          .map((quote) => `«${quote}»`)
          .join(', ')}. Det er ikke i seg selv et avvik — treffet kan gjelde et annet ` +
        'endepunkt eller et annet tidspunkt — men fraværet kan da ikke regnes som kontrollert.',
    )
  }

  if (!discharged) {
    return { discharged, notes }
  }
  return {
    discharged,
    notes: [
      `Et søk gjennom hele den reproduserte ${representationName(item)} fant ingen verdi for ` +
        `${notFound.map((field) => `«${field}»`).join(', ')} i noen passasje som navngir ` +
        `${arm}. Det betyr at opplysningen ikke står i den kildeversjonen raden viser til — ` +
        'ikke at den ikke står i publikasjonen: en representasjon kan mangle figurer, som er ' +
        'bilder, og et supplement, som er en egen fil.',
    ],
  }
}

function unique(fields: readonly EvidenceCheckField[]): readonly EvidenceCheckField[] {
  return [...new Set(fields)]
}

/**
 * Både `findings` og `rationale` er begrenset til 4000 tegn i basen
 * (`evidence_verifications_findings_format_check`,
 * `evidence_verifications_rationale_check`). Tekstene bygges av
 * `raw_extraction`, som er jsonb uten tilsvarende grense: mange eller lange
 * utdrag, eller lange nøkler, kan sprenge den.
 *
 * En for lang begrunnelse skal kortes ned framfor å felle registreringen av en
 * kontroll som faktisk ble gjennomført. Grensen håndheves derfor på *begge*
 * feltene og på hver vei ut av funksjonen, ikke bare på den ene teksten som
 * tilfeldigvis var lengst da regelen ble skrevet.
 */
const DATABASE_TEXT_LIMIT = 4000

function withinDatabaseLimit(text: string): string {
  const trimmed = text.trim()
  return trimmed.length <= DATABASE_TEXT_LIMIT
    ? trimmed
    : `${trimmed.slice(0, DATABASE_TEXT_LIMIT - 3).trimEnd()}…`
}

function joinSentences(parts: readonly string[]): string {
  return parts.join(' ')
}

/**
 * Kjører kontrollen og bygger raden `api.register_extraction_verification(...)`
 * skal ta imot.
 *
 * Kaller ingenting og skriver ingenting: hele avgjørelsen er en ren funksjon av
 * det registrerte funnet og den hentede kilden, slik at den kan prøves uten
 * database og uten nett — og slik at den samme inndataen alltid gir samme svar
 * (ANTIDEP_CONSTITUTION.md §17).
 */
export function checkExtraction(context: ExtractionCheckContext): ExtractionCheckReport {
  const { item, sourceText, representationReproduced } = context
  const projections = searchProjections(sourceText)
  const checked: EvidenceCheckField[] = []
  const findings: string[] = []
  const notes: string[] = []
  // Merknadene som forklarer hva kontrollen *ikke* fikk avgjort. `rationale`
  // får alle merknadene; `findings` får bare disse, slik at en uavklart rad
  // ikke åpner med hva som gikk bra.
  const unresolvedNotes: string[] = []
  const noteUnresolved = (text: string) => {
    notes.push(text)
    unresolvedNotes.push(text)
  }

  // 1. Sitatene. Den ene kontrollen som kan avkrefte en ekstraksjon alene.
  const quotes = verbatimQuotes(item.extraction.rawExtraction)
  const missingQuotes = quotes.filter((quote) => !verbatimOccursIn(projections, quote.text))
  const quotesChecked = quotes.length > 0
  const quotesFound = quotesChecked && missingQuotes.length === 0

  if (!quotesChecked) {
    // Ikke et hinder, og derfor ikke en uavklart merknad: kolonnen er valgfri,
    // og fra agentkontrakten er kildeforankringen kontrollgrunnlaget.
    // `workflow.required_check_fields` krever ikke feltet av en rad som ikke
    // har det (migrasjon 005y).
    notes.push(
      'Funnet har ingen ordrett gjengivelse i raw_extraction. Kolonnen er valgfri, og ' +
        'kontrollgrunnlaget er kildeforankringen, som er kontrollert for seg.',
    )
  } else {
    checked.push('raw_extraction')
    for (const quote of missingQuotes) {
      findings.push(
        `Det registrerte utdraget «${quote.key}» finnes ikke ordrett i representasjonen ` +
          `som ble hentet fra ${item.sourceVersion?.retrievedFrom ?? 'kilden'}.`,
      )
    }
    if (quotesFound) {
      notes.push(
        `${String(quotes.length)} ordrett utdrag ble gjenfunnet i representasjonen: ` +
          `${quotes.map((quote) => quote.key).join(', ')}.`,
      )
    }
  }

  // 2. Kildeforankringen. Hvert utdrag skal stå ordrett i nettopp denne
  //    kildeversjonen; et utdrag som ikke gjør det, er et avvik.
  const groundings = item.fieldGroundings
  const foundGroundings = groundings.filter((grounding) =>
    verbatimOccursIn(projections, grounding.sourceExcerpt),
  )
  const unfoundFields = new Set(
    groundings
      .filter((grounding) => !verbatimOccursIn(projections, grounding.sourceExcerpt))
      .map((grounding) => grounding.checkField),
  )
  for (const grounding of groundings) {
    if (unfoundFields.has(grounding.checkField)) {
      findings.push(
        `Kildeforankringen for «${grounding.checkField}» oppgir et utdrag som ikke finnes ` +
          `ordrett i representasjonen som ble hentet fra ` +
          `${item.sourceVersion?.retrievedFrom ?? 'kilden'}: «${grounding.sourceExcerpt}».`,
      )
    }
  }
  if (groundings.length > 0 && unfoundFields.size === 0) {
    notes.push(
      `${String(groundings.length)} forankrede utdrag ble gjenfunnet ordrett i ` +
        'representasjonen, ett per felt funnet påstår noe om.',
    )
  }

  // Et hull i forankringen er ikke et avvik, men gjør raden ukontrollerbar
  // felt for felt: det finnes ingen venstreside å bedømme feltet mot.
  const groundedFields = new Set(item.groundedCheckFields)
  const groundingGap = item.semanticCheckFields.filter((field) => !groundedFields.has(field))
  if (groundingGap.length > 0) {
    noteUnresolved(
      `Ekstraksjonen mangler kildeforankring for ${String(groundingGap.length)} av feltene den ` +
        `påstår noe om (${groundingGap.join(', ')}), og kan derfor ikke kontrolleres felt for ` +
        'felt. Antidep gjetter aldri et utdrag ut av den rå ekstraksjonen. Funnet må ' +
        'ekstraheres på nytt etter gjeldende protokoll.',
    )
  }

  // 3. Kildepekeren, som er maskinbeviset. Se hodekommentaren.
  //
  // Feltet føres opp under nøyaktig tre vilkår samtidig: representasjonen er
  // reprodusert, forankringen er komplett, og hvert forankret utdrag ble
  // gjenfunnet ordrett. Da — og bare da — er venstresiden bevist, og databasen
  // leser feltet som nettopp det beviset
  // (`workflow.grounding_machine_proved`, migrasjon 005y).
  //
  // `raw_extraction` inngår ikke i vilkåret. Kolonnen er valgfri, og fra
  // agentkontrakten er den ikke kontrollgrunnlaget — forankringen er. Et krav
  // om den ville gjort en helt gyldig agentekstraksjon uten `source_quote`
  // umulig å bevise, og dermed umulig å menneskebekrefte.
  const groundingProved =
    groundings.length > 0 && unfoundFields.size === 0 && groundingGap.length === 0
  if (representationReproduced && groundingProved) {
    checked.push('source_locator')
  } else if (!groundingProved && groundingGap.length === 0) {
    noteUnresolved(
      `Kildepekeren «${item.extraction.sourceLocator}» kunne ikke korroboreres uten en ` +
        'kildeforankring å finne igjen ordrett i representasjonen, og er derfor ikke ført ' +
        'opp som kontrollert.',
    )
  }

  // 4. Tallene. Et treff bekrefter; et manglende treff konkluderer ikke.
  //
  // Et felt føres opp som kontrollert bare når *alle* tallene under det ble
  // gjenfunnet. Konfidensintervallet er det som gjør regelen nødvendig: det har
  // to tall, og et felt som ble ført opp fordi den nedre grensen stemte, ville
  // påstått at intervallet var kontrollert selv om den øvre ikke var funnet.
  //
  // --------------------------------------------------------------------------
  // Tallene søkes i funnets egne utdrag, ikke i hele representasjonen
  //
  // En artikkel beskriver ofte flere armer og flere utfall. Søkes tallene i hele
  // teksten, kan treffet tilhøre et annet funn enn det som kontrolleres:
  //
  //   raden gjelder sertralin med sample_size = 48
  //   artikkelen sier «paroxetine, N = 48» et annet sted
  //
  // Feltet ble da ført opp i `checked_fields` fordi *en annen arm* hadde det
  // tallet. Bindingen som mangler, finnes allerede: `raw_extraction` er
  // funnets egne ordrette utdrag, og de er nettopp verifisert ord for ord mot
  // representasjonen. Tallene søkes derfor i dem.
  //
  // Er ingen utdrag gjenfunnet, finnes det ingen slik binding, og da føres
  // ingen tallfelt opp som kontrollert. Det er samme regel som gjelder
  // kildepekeren, og av samme grunn (DATABASE_ARCHITECTURE.md §29).
  //
  // --------------------------------------------------------------------------
  // …og utdraget må selv si hvilken arm det gjelder
  //
  // En samling verifiserte utdrag er ikke i seg selv en binding. Et funn kan ha
  // to utdrag der bare det ene navngir armen:
  //
  //   «Sertraline-treated patients were included in the trial.»
  //   «Paroxetine patients (N = 48) had mean weight change 1.5 kg (95% CI …).»
  //
  // Begge står ordrett i kilden, sertralin finnes, endepunktet finnes, og det
  // er nøyaktig én kandidat per felt — men alle tallene tilhører paroksetin.
  // Slått sammen til én tekst så det ut som en bekreftet sertralinrad.
  //
  // Tallene leses derfor bare fra de utdragene som *selv* navngir funnets
  // intervensjon. Et resultatutdrag som ikke sier hvilken arm det gjelder, kan
  // ikke bekrefte et tall for den armen — og da står feltet uavklart, ikke som
  // et avvik. Det er også en regel for redaktøren: et utdrag som skal
  // etterprøve et tall, må ta med armen tallet gjelder.
  //
  // Begrepene leses fra funnets egne utdrag av samme grunn: at legemiddelnavnet
  // står *et sted* i artikkelen, sier ingenting om denne raden.
  // --------------------------------------------------------------------------
  //
  // Fra migrasjon 005u av er de forankrede utdragene også radens egne, ordrette
  // og nettopp verifisert mot representasjonen. De hører derfor med i den samme
  // høystakken: mer tekst som beviselig tilhører dette funnet, uten at kravet
  // om at armen og endepunktet står i samme treff er rørt.
  const groundedExcerpts = foundGroundings.map((grounding) => grounding.sourceExcerpt)
  const ownText = [...(quotesFound ? quotes.map((quote) => quote.text) : []), ...groundedExcerpts]
  const quoteProjections = ownText.flatMap((text) => searchProjections(text))
  // Et utvalg hører til armen; et estimat og et konfidensintervall hører til
  // *ett endepunkt hos den armen*. To korrekte utdrag kan ellers settes sammen
  // til en gal rad:
  //
  //   «Sertraline-treated patients had a mean change of 5.0 points on HAM-D.»
  //   «Body weight change was the prespecified primary outcome.»
  //
  // Begge er sanne, begge står ordrett i kilden, og sammen «bekreftet» de en
  // sertralinrad om vektendring med estimat 5,0 — et tall som hører til HAM-D.
  //
  // Bindingen er derfor ikke på utdraget, og heller ikke på setningen. Et helt
  // utdrag som nevner riktig arm er ikke nok, for det kan nevne flere — men det
  // kan én setning også:
  //
  //   «Sertraline and paroxetine were compared, and body weight change was
  //    5.0 kg (95% CI 4.0 to 6.0) in paroxetine patients.»
  //
  // Setningen navngir både sertralin og endepunktet, og hvert tall i den
  // tilhører paroksetin. Kravet er derfor at armen, endepunktet og verdien står
  // i **samme sammenhengende treff** (`anchoredNumberMatch`, `withTerms`), med
  // bare tillatt lim imellom. Setningsdelingen står igjen som et billigere
  // forfilter foran det samme kravet.
  //
  // Konsekvensen er skrevet ut framfor pyntet på: katalogen er på norsk og
  // kildene på engelsk, så et endepunkt som «vektendring» sjelden står i en
  // engelsk kilde. Estimat og konfidensintervall vil derfor stå uavklart for de
  // fleste reelle kilder inntil et ledd som forstår språk finnes. Det er den
  // riktige enden å ta feil i: alternativet er en bekreftelse som bygger på at
  // to sanne setninger om forskjellige ting stod i samme artikkel.
  const quoteFragments = quoteProjections.flatMap(sentences)
  const claimProjections = quoteFragments.filter((fragment) =>
    termOccursIn([fragment], item.extraction.interventionDrugName),
  )
  const unmatchedNumbers: string[] = []
  const numericFields = new Set<EvidenceCheckField>()
  const unresolvedFields = new Set<EvidenceCheckField>()
  const ambiguousNumbers: string[] = []
  let confirmedEstimate: string | null = null
  for (const claim of numericClaims(item)) {
    numericFields.add(claim.field)
    const match = anchoredNumberMatch(claimProjections, claim)
    if (match.kind === 'ambiguous') {
      unresolvedFields.add(claim.field)
      ambiguousNumbers.push(`${claim.label} (${match.candidates.join(', ')})`)
    } else if (match.kind === 'missing') {
      unresolvedFields.add(claim.field)
      unmatchedNumbers.push(`${claim.label} (${claim.value})`)
    } else if (claim.field === 'estimate') {
      confirmedEstimate = claim.value
    }
  }
  // Konfidensintervallet kontrolleres som ett uttrykk, ikke som tre tall — se
  // hodekommentaren over `confidenceIntervalCheck`.
  const reportedInterval = reportedConfidenceInterval(item)
  let confidenceIntervalUnresolved = false
  if (reportedInterval !== null) {
    numericFields.add('confidence_interval')
    const ci = confidenceIntervalCheck(
      claimProjections,
      reportedInterval,
      [
        termAnchor(item.extraction.interventionDrugName),
        termAnchor(item.extraction.outcomeLabel),
        // Intervallet hører til samme kontrast og samme populasjon som
        // estimatet. Se `contextElements` for estimatet.
        ...comparatorElements(item.extraction),
        ...populationElements(item.extraction),
      ],
      [
        ...sampleSizeExpressions(item.extraction),
        ...estimateExpressions(item.extraction, confirmedEstimate),
      ],
    )
    if (!ci.confirmed) {
      unresolvedFields.add('confidence_interval')
      confidenceIntervalUnresolved = true
      if (ci.ambiguous.length > 0) {
        ambiguousNumbers.push(`konfidensintervall (${ci.ambiguous.join('; ')})`)
      } else if (ci.noAnchor) {
        noteUnresolved(
          'Representasjonen navngir ikke noe konfidensintervall, så det registrerte ' +
            'intervallet kunne ikke kontrolleres som ett uttrykk og er ikke ført opp som ' +
            'kontrollert. Grensene kan stå i en tabell eller uten at intervallet er navngitt.',
        )
      } else {
        unmatchedNumbers.push(...ci.unmatched)
        if (ci.unmatched.length === 0) {
          noteUnresolved(
            'Nivået og grensene i det registrerte konfidensintervallet ble funnet hver for ' +
              'seg, men ikke i samme intervalluttrykk i kilden. Intervallet er derfor ikke ' +
              'ført opp som kontrollert: tre tall fra tre steder er ikke ett intervall.',
          )
        }
      }
    }
  }

  for (const field of numericFields) {
    if (!unresolvedFields.has(field) && !unfoundFields.has(field)) {
      checked.push(field)
    }
  }
  if (numericFields.size > 0 && claimProjections.length === 0) {
    noteUnresolved(
      ownText.length > 0
        ? `Ingen av funnets ordrette utdrag navngir intervensjonen «${item.extraction.interventionDrugName}», så ` +
            'tallene hadde ingen tekst som entydig tilhører denne armen å kontrolleres mot. En ' +
            'artikkel beskriver ofte flere armer, og et tall i et utdrag som ikke sier hvilken ' +
            'arm det gjelder, kan tilhøre en annen.'
        : 'Ingen av funnets ordrette utdrag ble gjenfunnet i representasjonen, så tallene hadde ' +
            'ingen tekst som tilhører nettopp dette funnet å kontrolleres mot. En artikkel kan ' +
            'beskrive flere armer og flere utfall, og et treff et annet sted i den ville tilhørt ' +
            'et annet funn.',
    )
  }
  if (ambiguousNumbers.length > 0) {
    noteUnresolved(
      'Utdraget oppgir flere verdier for de samme feltene, og kontrollen kan ikke avgjøre ' +
        `hvilken som er denne radens: ${ambiguousNumbers.join(', ')}. Et utdrag som beskriver ` +
        'flere armer eller flere utfall, binder ikke maskinelt ett av tallene til nettopp dette ' +
        'funnet, og feltene står derfor uavklart framfor bekreftet.',
    )
  }
  if (unmatchedNumbers.length > 0) {
    noteUnresolved(
      `Følgende oppgitte tall ble ikke gjenfunnet som tall i funnets egne utdrag, og er derfor ` +
        `ikke ført opp som kontrollert: ${unmatchedNumbers.join(', ')}. Et tall kan stå ` +
        'skrevet med bokstaver, i en annen enhet eller i en tabell som ikke er med i denne ' +
        'representasjonen, så et manglende treff er ikke i seg selv et avvik.',
    )
  }

  // 4b. Det kildeomfattende søket, når raden fører et globalt fravær.
  //
  // Egen del, fordi den er den ene halvdelen av en fraværspåstand et menneske
  // aldri kan bære: kontrolløkten ser ett lokalt utdrag, og dette er et søk
  // gjennom hele representasjonen (migrasjon 005ae). Feltet føres opp bare når
  // *alle* de globalt fraværende feltene er avklart, og en merknad sier alltid
  // hva søket faktisk gjennomsøkte.
  const absence = sourceWideAbsenceCheck(context)
  if (item.sourceWideAbsenceFields.length > 0) {
    if (absence.discharged) {
      checked.push('source_wide_absence')
      notes.push(...absence.notes)
    } else {
      for (const note of absence.notes) {
        noteUnresolved(note)
      }
    }
  }

  // 5. Begrepene. Bare bekreftelse teller; se hodekommentaren.
  const unmatchedTerms: string[] = []
  for (const claim of termClaims(item)) {
    // Et felt hvis eget forankringsutdrag ikke stod i kilden, kan aldri føres
    // opp som kontrollert: grunnlaget det skulle bedømmes mot, er falsifisert.
    if (termOccursIn(quoteProjections, claim.term) && !unfoundFields.has(claim.field)) {
      checked.push(claim.field)
    } else if (!unfoundFields.has(claim.field)) {
      unmatchedTerms.push(`${claim.label} («${claim.term}»)`)
    }
  }
  if (unmatchedTerms.length > 0) {
    noteUnresolved(
      `Følgende begreper ble ikke gjenfunnet ordrett i kilden og er derfor ikke ført opp ` +
        `som kontrollert: ${unmatchedTerms.join(', ')}. Kilden er som regel på engelsk mens ` +
        'katalogen er på norsk, så et manglende treff er ikke i seg selv et avvik.',
    )
  }

  // At begrepene finnes, er ikke det samme som at raden finnes. Se
  // hodekommentaren over `termsBoundTogether` og `termBindings`.
  const bindingGlue = [
    ...sampleSizeExpressions(item.extraction),
    ...estimateExpressions(
      item.extraction,
      isReported(item.extraction.estimateAvailability) ? item.extraction.estimate : null,
    ),
  ]
  const rowBound =
    unmatchedTerms.length > 0 ||
    boundTogether(quoteFragments, rowBindingElements(item), bindingGlue)
  if (!rowBound) {
    noteUnresolved(
      'Begrepene ble gjenfunnet, men ingen av funnets ordrette utdrag sier ' +
        `${rowBindingDescription(item)} i samme påstand. Et utdrag som nevner delene hver for ` +
        'seg — eller som benekter forholdet, eller tilskriver det en annen arm eller et annet ' +
        'utfall — er ikke støtte for at nettopp denne raden stemmer. Raden er derfor ikke ført ' +
        'opp som bekreftet.',
    )
  }

  // 6. Utfallet.
  //
  // Rekkefølgen er ikke tilfeldig: et avvik er sterkere enn en manglende
  // kontroll, og en manglende kontroll er sterkere enn en bekreftelse. En
  // kontroll som ikke konkluderte, skal aldri leses som en bekreftelse
  // (ANTIDEP_CONSTITUTION.md §6, §11).
  let outcome: VerificationOutcome
  if (findings.length > 0) {
    outcome = 'needs_correction'
  } else if (!representationReproduced) {
    outcome = 'uncertain'
    noteUnresolved(
      'Representasjonen som ble hentet, har ikke samme fingeravtrykk som den registrerte ' +
        'kildeversjonen, så kontrollen gjelder ikke den utgaven ekstraksjonen ble gjort fra.',
    )
  } else if (
    !groundingProved ||
    unmatchedNumbers.length > 0 ||
    ambiguousNumbers.length > 0 ||
    confidenceIntervalUnresolved ||
    unmatchedTerms.length > 0 ||
    !rowBound
  ) {
    // Et oppgitt tall som ikke lot seg gjenfinne, er ikke et avvik — men det er
    // heller ikke en bekreftelse av raden som helhet. Utfallet sier nettopp det.
    //
    // Konfidensintervallet står her selv om hvert av tallene fantes et sted i
    // teksten: fant kontrollen dem ikke i samme intervalluttrykk, er intervallet
    // ikke kontrollert, og en rad med et ukontrollert intervall er ikke bekreftet.
    //
    // Begrepene står her av samme grunn, og uten dem kunne et ordrett — men
    // fullstendig irrelevant — utdrag bære hele raden. En rad uten oppgitte
    // tallfelt har da ingenting annet å bli kontrollert på:
    //
    //   raden gjelder «sertraline» og «weight change»
    //   utdraget sier «The trial was randomized and double blind.»
    //
    // Sitatet finnes ordrett i riktig kildeversjon, kildepekeren korroboreres,
    // ingen tallkontroll kan slå ut — og utfallet ble `verified`, uten at
    // kontrollen noen gang hadde sett at utdraget handlet om dette
    // legemiddelet eller dette endepunktet. Databasen fanger det ikke: den
    // krever `source_locator` i `checked_fields` for `verified`, ikke armen
    // eller endepunktet.
    //
    // Fortsatt ikke et avvik: et begrep som ikke er gjenfunnet, betyr som
    // regel bare at katalogen er på norsk og kilden på engelsk. Men det er
    // heller ikke en bekreftelse (ANTIDEP_CONSTITUTION.md §6, §11).
    outcome = 'uncertain'
  } else {
    outcome = 'verified'
  }

  const method =
    'Deterministisk ekstraksjonskontroll: representasjonen ble hentet på nytt fra ' +
    `${item.sourceVersion?.retrievedFrom ?? 'kildeversjonens adresse'} og ` +
    (representationReproduced
      ? 'ga samme sha256-fingeravtrykk som den registrerte kildeversjonen'
      : 'ga et annet sha256-fingeravtrykk enn den registrerte kildeversjonen') +
    '. Hvert ordrett utdrag i raw_extraction og hvert utdrag i kildeforankringen ble søkt ' +
    'ordrett, og hvert oppgitt tall ble søkt som selvstendig tall i funnets egne utdrag, i ' +
    'både råsvaret og en taggfri projeksjon av det. Ingen språkmodell er brukt.'

  // `findings` er påkrevd for alt annet enn `verified`
  // (`evidence_verifications_findings_required_check`, migrasjon 005), og
  // regelen er riktig: en rad som ikke er bekreftet, skal si hvorfor der en
  // leser ser etter det. For `uncertain` er svaret ikke et avvik, men at
  // kontrollen ikke konkluderte — og setningen begynner med nettopp de ordene,
  // slik at den ikke kan leses som en anklage. Hva som er hva, står uansett i
  // `outcome`.
  //
  // Uten dette ble en helt normal uavklart kontroll avvist av databasen, og
  // hele agentkjøringen falt (§74.33).
  const unresolved = joinSentences([
    'Kontrollen konkluderte ikke, og dette er ikke et avvik:',
    ...unresolvedNotes,
  ])

  return {
    outcome,
    checkedFields: unique(checked),
    findings:
      findings.length > 0
        ? withinDatabaseLimit(joinSentences(findings))
        : outcome === 'verified'
          ? null
          : withinDatabaseLimit(unresolved),
    rationale: withinDatabaseLimit(joinSentences([method, ...notes])),
  }
}
