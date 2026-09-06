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

import type { VerificationItem } from './verification-input.ts'

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
  | 'limitations'
  | 'source_locator'
  | 'raw_extraction'

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

/** Ordrett forekomst. Brukes på sitater, som er lange og entydige i seg selv. */
function occursIn(projections: readonly string[], needle: string): boolean {
  const wanted = normalize(needle)
  if (wanted.length === 0) {
    return false
  }
  return projections.some((haystack) => haystack.includes(wanted))
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
    })
  }
  if (isReported(e.estimateAvailability) && e.estimate !== null) {
    claims.push({
      field: 'estimate',
      label: 'estimat',
      value: e.estimate,
      anchorsBefore: ESTIMATE_ANCHORS,
      anchorsAfter: ESTIMATE_ANCHORS,
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
  'and',
  'the',
  'with',
  'var',
  'er',
  'med',
  'fra',
  'og',
  'på',
] as const

/** Skilletegnene som får være lim. Ingen bokstaver, og ikke punktum. */
const GLUE_PUNCTUATION = '[\\s:;,=()\\[\\]/-]'

/** Lim, eventuelt med ekstra former som er nøytrale for nettopp dette uttrykket. */
function glue(extra: readonly string[] = []): string {
  return `(?:${[GLUE_PUNCTUATION, ...extra, ...CI_GLUE_WORDS].join('|')}){0,12}`
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
function candidatesNear(
  projections: readonly string[],
  anchorsBefore: readonly string[],
  anchorsAfter: readonly string[],
  extraGlue: readonly string[] = [],
): Set<string> {
  const g = glue(extraGlue)
  const patterns: string[] = []
  if (anchorsBefore.length > 0) {
    patterns.push(`(?:${anchorsBefore.join('|')})${g}${ANY_NUMBER}`)
  }
  if (anchorsAfter.length > 0) {
    patterns.push(`${ANY_NUMBER}${g}(?:${anchorsAfter.join('|')})`)
  }

  const candidates = new Set<string>()
  for (const pattern of patterns) {
    for (const projection of projections) {
      // `u` er nødvendig: uten den er `\p{L}` i et begrepsanker bokstavene
      // «p{L}» og ikke en bokstavklasse.
      for (const hit of projection.matchAll(new RegExp(pattern, 'giu'))) {
        const found = hit[1]
        if (found !== undefined) {
          candidates.add(sameNumber(found))
        }
      }
    }
  }
  return candidates
}

/** Begrepet som mønster, med samme ordgrense som `termOccursIn`. */
function termAnchor(term: string): string {
  return `${escapeRegExp(normalize(term))}\\p{L}{0,2}`
}

function anchoredNumberMatch(
  projections: readonly string[],
  value: string,
  anchorsBefore: readonly string[],
  anchorsAfter: readonly string[],
  contextTerms: readonly string[],
): AnchoredNumberMatch {
  // Tallet må stå inntil *alle* kravene: feltets eget anker («N =»,
  // «difference»), og hvert bindende begrep — armen, og for effektmål
  // endepunktet.
  //
  // At begrepet står et sted i samme setning er ikke nok. «Sertraline was
  // compared with paroxetine patients (N = 48)» er én setning som navngir
  // sertralin, men 48 står inntil paroksetin. Og «a mean HAM-D change of 5.0
  // points, while body weight change was also recorded» navngir både armen og
  // endepunktet, mens 5,0 hører til HAM-D. Bare nærheten skiller dem.
  // Feltets eget anker er nøytralt lim for begrepskontrollen: i «sertraline
  // patients (N = 284)» står «N =» mellom armen og tallet, og det er nettopp
  // det ankeret som gjør tallet til en utvalgsstørrelse.
  const anchorGlue = [...anchorsBefore, ...anchorsAfter]
  const sets = [
    candidatesNear(projections, anchorsBefore, anchorsAfter),
    ...contextTerms.map((term) =>
      candidatesNear(projections, [termAnchor(term)], [termAnchor(term)], anchorGlue),
    ),
  ]
  const [first = new Set<string>(), ...rest] = sets
  const candidates = new Set([...first].filter((n) => rest.every((set) => set.has(n))))

  if (candidates.size === 0) {
    return { kind: 'missing' }
  }
  if (candidates.size > 1) {
    return { kind: 'ambiguous', candidates: [...candidates].sort() }
  }
  return candidates.has(sameNumber(value)) ? { kind: 'confirmed' } : { kind: 'missing' }
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
 * Uttrykket med endepunktet foran eller bak.
 *
 * Uten dette kunne et intervall som tilhører et annet endepunkt i samme setning
 * bekrefte raden: «a mean HAM-D change of 5.0 points (95% CI 4.0 to 6.0), while
 * body weight change was also recorded» navngir endepunktet, men intervallet er
 * HAM-D-ens. Limet slipper igjennom radens eget estimat — intervallet hører til
 * det — og ellers ingen tall.
 */
function withOutcome(order: string, outcomeTerm: string, estimate: string | null): string[] {
  const estimateNumber = estimate === null ? null : numberPattern(estimate)
  const g = glue([CI_ANCHOR_SOURCE, ...(estimateNumber === null ? [] : [estimateNumber.body])])
  const outcome = termAnchor(outcomeTerm)
  return [`${outcome}${g}${order}`, `${order}${g}${outcome}`]
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

function confidenceIntervalPatterns(
  interval: ConfidenceInterval,
  outcomeTerm: string,
  estimate: string | null,
): readonly string[] {
  const level = levelPattern(interval.levelPercent)
  const bounds = boundsPattern(interval.lower, interval.upper)
  if (level === null || bounds === null) {
    return []
  }
  return intervalOrders(level, bounds).flatMap((order) => withOutcome(order, outcomeTerm, estimate))
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
  /** Endepunktet uttrykket må stå inntil. */
  outcomeTerm: string,
  /** Radens eget estimat, når det er bekreftet. Det er lim, ikke et fremmedlegeme. */
  confirmedEstimate: string | null,
): ConfidenceIntervalReport {
  const candidates = confidenceIntervalCandidates(projections)
  if (candidates.length > 1) {
    return { confirmed: false, unmatched: [], noAnchor: false, ambiguous: candidates }
  }

  const patterns = confidenceIntervalPatterns(interval, outcomeTerm, confirmedEstimate)
  if (
    patterns.some((pattern) =>
      projections.some((projection) => new RegExp(pattern, 'iu').test(projection)),
    )
  ) {
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

function termClaims(item: VerificationItem): readonly TermClaim[] {
  const e = item.extraction
  const claims: TermClaim[] = [
    { field: 'intervention_arm', label: 'intervensjon', term: e.interventionDrugName },
    { field: 'outcome', label: 'endepunkt', term: e.outcomeLabel },
  ]
  if (e.comparatorKind === 'drug' && e.comparatorDrugName !== null) {
    claims.push({ field: 'comparator_arm', label: 'komparator', term: e.comparatorDrugName })
  }
  if (e.populationLabel !== null && isReported(e.populationAvailability)) {
    claims.push({ field: 'population', label: 'populasjon', term: e.populationLabel })
  }
  return claims
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
  const missingQuotes = quotes.filter((quote) => !occursIn(projections, quote.text))
  const quotesChecked = quotes.length > 0
  const quotesFound = quotesChecked && missingQuotes.length === 0

  if (!quotesChecked) {
    noteUnresolved(
      'Funnet har ingen ordrett gjengivelse fra kilden (raw_extraction), så ' +
        'sitatkontrollen kunne ikke gjennomføres.',
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

  // 2. Kildepekeren. Se hodekommentaren for hva som gjør den korroborert.
  if (representationReproduced && quotesFound) {
    checked.push('source_locator')
  } else if (!quotesFound) {
    noteUnresolved(
      `Kildepekeren «${item.extraction.sourceLocator}» kunne ikke korroboreres uten et ` +
        'sitat å finne igjen i representasjonen, og er derfor ikke ført opp som kontrollert.',
    )
  }

  // 3. Tallene. Et treff bekrefter; et manglende treff konkluderer ikke.
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
  const quoteProjections = quotesFound
    ? quotes.flatMap((quote) => searchProjections(quote.text))
    : []
  // Et utvalg hører til armen; et estimat og et konfidensintervall hører til
  // *ett endepunkt hos den armen*. To korrekte utdrag kan ellers settes sammen
  // til en gal rad:
  //
  //   «Sertraline-treated patients had a mean change of 5.0 points on HAM-D.»
  //   «Body weight change was the prespecified primary outcome.»
  //
  // Begge er sanne, begge står ordrett i kilden, og sammen «bekreftet» de en
  // sertralinrad om vektendring med estimat 5,0 — et tall som hører til HAM-D.
  // Effektmålene krever derfor et utdrag som navngir både armen og endepunktet.
  //
  // Konsekvensen er skrevet ut framfor pyntet på: katalogen er på norsk og
  // kildene på engelsk, så et endepunkt som «vektendring» sjelden står i en
  // engelsk kilde. Estimat og konfidensintervall vil derfor stå uavklart for de
  // fleste reelle kilder inntil et ledd som forstår språk finnes. Det er den
  // riktige enden å ta feil i: alternativet er en bekreftelse som bygger på at
  // to sanne setninger om forskjellige ting stod i samme artikkel.
  // Bindingen er på *setningen*, ikke på utdraget. Et helt utdrag som nevner
  // riktig arm er ikke nok, for det kan nevne flere:
  //
  //   «Sertraline and paroxetine were compared; paroxetine patients (N = 48) …»
  //   «Sertraline … a mean change of 5.0 points on HAM-D; body weight change …»
  //
  // Begge navngir det raden trenger, og i begge tilhører tallet noe annet.
  // Utdragene deles derfor i setninger, og et tall teller bare fra en setning
  // som selv navngir armen — og for effektmål endepunktet.
  const quoteFragments = quotesFound
    ? quotes.flatMap((quote) => searchProjections(quote.text)).flatMap(sentences)
    : []
  const armFragments = quoteFragments.filter((fragment) =>
    termOccursIn([fragment], item.extraction.interventionDrugName),
  )
  const outcomeBoundFragments = armFragments.filter((fragment) =>
    termOccursIn([fragment], item.extraction.outcomeLabel),
  )

  const claimProjections = armFragments
  const outcomeBoundProjections = outcomeBoundFragments
  const unmatchedNumbers: string[] = []
  const numericFields = new Set<EvidenceCheckField>()
  const unresolvedFields = new Set<EvidenceCheckField>()
  const ambiguousNumbers: string[] = []
  let confirmedEstimate: string | null = null
  for (const claim of numericClaims(item)) {
    numericFields.add(claim.field)
    const match = anchoredNumberMatch(
      claim.field === 'sample_size' ? claimProjections : outcomeBoundProjections,
      claim.value,
      claim.anchorsBefore,
      claim.anchorsAfter,
      // Et utvalg er et antall personer i en arm, og bindes til armen. Et
      // estimat er verdien av et endepunkt, og bindes til endepunktet — armen
      // er allerede bundet på setningen. Å kreve begge inntil samme tall ville
      // krevd at armen sto klistret til verdien, og det gjør den nesten aldri:
      // armen er setningens subjekt og endepunktet står imellom.
      claim.field === 'sample_size'
        ? [item.extraction.interventionDrugName]
        : [item.extraction.outcomeLabel],
    )
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
      outcomeBoundProjections,
      reportedInterval,
      item.extraction.outcomeLabel,
      confirmedEstimate,
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
    if (!unresolvedFields.has(field)) {
      checked.push(field)
    }
  }
  if (numericFields.size > 0 && claimProjections.length === 0) {
    noteUnresolved(
      quotesFound
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

  // 4. Begrepene. Bare bekreftelse teller; se hodekommentaren.
  const unmatchedTerms: string[] = []
  for (const claim of termClaims(item)) {
    if (termOccursIn(quoteProjections, claim.term)) {
      checked.push(claim.field)
    } else {
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

  // 5. Utfallet.
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
    !quotesFound ||
    unmatchedNumbers.length > 0 ||
    ambiguousNumbers.length > 0 ||
    confidenceIntervalUnresolved
  ) {
    // Et oppgitt tall som ikke lot seg gjenfinne, er ikke et avvik — men det er
    // heller ikke en bekreftelse av raden som helhet. Utfallet sier nettopp det.
    //
    // Konfidensintervallet står her selv om hvert av tallene fantes et sted i
    // teksten: fant kontrollen dem ikke i samme intervalluttrykk, er intervallet
    // ikke kontrollert, og en rad med et ukontrollert intervall er ikke bekreftet.
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
    '. Hvert ordrett utdrag i raw_extraction ble søkt ordrett, og hvert oppgitt tall ble ' +
    'søkt som selvstendig tall, i både råsvaret og en taggfri projeksjon av det. Ingen ' +
    'språkmodell er brukt.'

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
