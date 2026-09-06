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

/** De to høystakkene et søk gjøres mot. */
export function searchProjections(sourceText: string): readonly string[] {
  const raw = normalize(decodeEntities(sourceText))
  const withoutTags = normalize(decodeEntities(stripTags(sourceText)))
  return raw === withoutTags ? [raw] : [raw, withoutTags]
}

function occursIn(projections: readonly string[], needle: string): boolean {
  const wanted = normalize(needle)
  if (wanted.length === 0) {
    return false
  }
  return projections.some((haystack) => haystack.includes(wanted))
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

/** Om tallet står i teksten som et selvstendig tall, med riktig fortegn. */
export function numberOccursIn(projections: readonly string[], value: string): boolean {
  const normalized = trimNumericText(value).replace(/^\+/, '')
  if (!/^-?\d+(\.\d+)?$/.test(normalized)) {
    return false
  }

  const isNegative = normalized.startsWith('-')
  const digits = normalized.replace('-', '')
  const [integerPart = '', decimalPart] = digits.split('.')
  const body =
    decimalPart === undefined
      ? escapeRegExp(integerPart)
      : `${escapeRegExp(integerPart)}[.,]${escapeRegExp(decimalPart)}0*`

  // Foran: et negativt tall krever minustegnet, og minustegnet må selv ikke
  // stå rett etter et tall — ellers ville «8-12» blitt lest som «-12». Et
  // positivt tall avvises når det står med minustegn foran.
  //
  // `normalize()` har allerede gjort typografiske minus- og bindestreker om til
  // ASCII, så det er nok å se etter ett tegn her.
  const before = isNegative ? '(?<![\\d.,])-' : '(?<![\\d.,-])'
  // Bak: verken et siffer til, eller et desimalskilletegn med et siffer etter.
  // Uten det siste ville «12» blitt funnet inne i «12.5».
  const after = '(?![\\d]|[.,]\\d)'

  const pattern = new RegExp(`${before}${body}${after}`)
  return projections.some((haystack) => pattern.test(haystack))
}

// ----------------------------------------------------------------------------
// Selve kontrollen
// ----------------------------------------------------------------------------

interface NumericClaim {
  readonly field: EvidenceCheckField
  readonly label: string
  readonly value: string
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
    })
  }
  if (isReported(e.estimateAvailability) && e.estimate !== null) {
    claims.push({ field: 'estimate', label: 'estimat', value: e.estimate })
  }
  if (isReported(e.confidenceIntervalAvailability)) {
    if (e.ciLower !== null) {
      claims.push({
        field: 'confidence_interval',
        label: 'nedre konfidensgrense',
        value: e.ciLower,
      })
    }
    if (e.ciUpper !== null) {
      claims.push({
        field: 'confidence_interval',
        label: 'øvre konfidensgrense',
        value: e.ciUpper,
      })
    }
    // Nivået hører til intervallet, ikke ved siden av det: «0,4 til 2,6» er
    // en annen påstand med 90 % enn med 95 %. Databasen krever da også begge
    // eller ingen (`evidence_items_confidence_level_pairing_check`). Uten
    // denne kontrollen ville `confidence_interval` blitt ført som kontrollert
    // mot en kilde som oppgir et annet nivå enn det registrerte — og
    // auditsporet ville sagt at intervallet var etterprøvd.
    if (e.ciLevelPercent !== null) {
      claims.push({
        field: 'confidence_interval',
        label: 'konfidensnivå',
        value: e.ciLevelPercent,
      })
    }
  }
  return claims
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

  // 1. Sitatene. Den ene kontrollen som kan avkrefte en ekstraksjon alene.
  const quotes = verbatimQuotes(item.extraction.rawExtraction)
  const missingQuotes = quotes.filter((quote) => !occursIn(projections, quote.text))
  const quotesChecked = quotes.length > 0
  const quotesFound = quotesChecked && missingQuotes.length === 0

  if (!quotesChecked) {
    notes.push(
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
    notes.push(
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
  const unmatchedNumbers: string[] = []
  const numericFields = new Set<EvidenceCheckField>()
  const unresolvedFields = new Set<EvidenceCheckField>()
  for (const claim of numericClaims(item)) {
    numericFields.add(claim.field)
    if (!numberOccursIn(projections, claim.value)) {
      unresolvedFields.add(claim.field)
      unmatchedNumbers.push(`${claim.label} (${claim.value})`)
    }
  }
  for (const field of numericFields) {
    if (!unresolvedFields.has(field)) {
      checked.push(field)
    }
  }
  if (unmatchedNumbers.length > 0) {
    notes.push(
      `Følgende oppgitte tall ble ikke gjenfunnet som tall i representasjonen, og er derfor ` +
        `ikke ført opp som kontrollert: ${unmatchedNumbers.join(', ')}. Et tall kan stå ` +
        'skrevet med bokstaver, i en annen enhet eller i en tabell som ikke er med i denne ' +
        'representasjonen, så et manglende treff er ikke i seg selv et avvik.',
    )
  }

  // 4. Begrepene. Bare bekreftelse teller; se hodekommentaren.
  const unmatchedTerms: string[] = []
  for (const claim of termClaims(item)) {
    if (occursIn(projections, claim.term)) {
      checked.push(claim.field)
    } else {
      unmatchedTerms.push(`${claim.label} («${claim.term}»)`)
    }
  }
  if (unmatchedTerms.length > 0) {
    notes.push(
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
    notes.push(
      'Representasjonen som ble hentet, har ikke samme fingeravtrykk som den registrerte ' +
        'kildeversjonen, så kontrollen gjelder ikke den utgaven ekstraksjonen ble gjort fra.',
    )
  } else if (!quotesFound || unmatchedNumbers.length > 0) {
    // Et oppgitt tall som ikke lot seg gjenfinne, er ikke et avvik — men det er
    // heller ikke en bekreftelse av raden som helhet. Utfallet sier nettopp det.
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

  return {
    outcome,
    checkedFields: unique(checked),
    findings: findings.length > 0 ? joinSentences(findings) : null,
    rationale: joinSentences([method, ...notes]),
  }
}
