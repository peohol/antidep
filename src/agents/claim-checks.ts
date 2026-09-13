// ============================================================================
// Den deterministiske claim-kontrollen
//
// EVIDENCE_PIPELINE.md §39 stiller ett spørsmål: «støtter denne kilden faktisk
// denne konkrete påstanden slik den er formulert?» DATABASE_ARCHITECTURE.md §30
// deler det i sju kontrollpunkter, og migrasjon 005 håndhever at ingen av dem
// kan hoppes over.
//
// Denne modulen svarer på dem deterministisk, uten et språkmodellkall.
// ANTIDEP_CONSTITUTION.md §17 ber om determinisme «der det er mulig», og for
// disse punktene er det mulig for en del av spørsmålet: påstandens strukturerte
// betydning — populasjon, komparator, tidsrom, retning og størrelse — kan
// sammenlignes felt for felt med det registrerte evidensgrunnlaget.
//
// ----------------------------------------------------------------------------
// Et avvik krever at lenken faktisk lovet samsvar
//
// Den ene garantien kontrollen hviler på, er at **hvert `deviation` den melder,
// er et faktisk avvik**. En kontroll som anklager en korrekt påstand, er verre
// enn ingen kontroll (§74.33), og konsekvensen her er `needs_correction` på
// klinisk innhold som ikke feiler noe.
//
// Derfor er ikke enhver feltforskjell et avvik. `partially_supports` betyr
// «underbygger deler av den, for eksempel retningen men ikke størrelsen», og
// `directness = indirect` betyr at funnet treffer påstandens populasjon,
// endepunkt, komparator og tidsrom bare indirekte — ingen av dem registrerer
// *hvilken* akse som ikke er dekket. En forskjell på en slik lenke kan derfor
// være nettopp det lenken erkjenner, og er uavklart og ikke feil.
//
// Bare `supports` + `direct` lover samsvar på hver akse, og bare der kan en
// forskjell meldes som avvik (`promisesCorrespondence`). Det svekker ingen
// sperre: `not_assessable` er like blokkerende for publiseringsgaten som
// `deviation`. Det som faller bort, er anklagen — ikke kontrollen.
//
// ----------------------------------------------------------------------------
// Asymmetrien er den samme som i ekstraksjonskontrollen, og strengere
//
// Kontrollen kan **falsifisere**, men aldri **bekrefte**. Det er ikke en
// begrensning som skal rettes senere; det følger av hva punktene spør om:
//
//   * «Støtter grunnlaget ordlyden?» krever språkforståelse. Det den
//     deterministiske kontrollen kan avgjøre, er om det i det hele tatt finnes
//     en støttende lenke, og om utdragene ekstraksjonen bygger på fortsatt står
//     i kildens representasjon. Begge deler kan avkrefte; ingen av dem kan
//     bekrefte at formuleringen er dekket.
//   * «Mangler vesentlige forbehold?» krever den samme forståelsen. Ett tilfelle
//     er likevel falsifiserbart: et grunnlag som er indirekte, delvis støttende
//     eller motstridende, uten et eneste forbehold i påstanden.
//   * «Finnes relevant motstridende evidens som ikke er representert?» kan
//     **aldri** besvares med ok herfra. Basen kjenner bare den evidensen Antidep
//     har registrert, og fravær av registrert motstridende evidens er ikke
//     fravær av motstridende evidens (ANTIDEP_CONSTITUTION.md §17).
//
// Et `verified` krever at alle sju punktene er `ok`
// (claim_verifications_verified_requires_all_ok_check). Punkt sju er alltid
// `not_assessable`, så **denne kontrollen kan ikke produsere en bekreftelse**,
// og publiseringsgatens G9 vil blokkere på resultatet. Det er riktig svar: en
// kontroll som ikke konkluderte, er ikke en bekreftelse (§6, §11). Et senere
// ledd med språkmodell, eller en menneskelig reviewer, er det som kan
// konkludere — og det er et adapterbytte, ikke en datamodellendring (§20).
//
// ----------------------------------------------------------------------------
// Hvilke lenker som teller for hvilket punkt
//
// Påstandens strukturerte betydning hviler på de lenkene som faktisk underbygger
// den: `supports` og `partially_supports`. En `contradicts`-lenke skal ikke
// felles for at den «peker feil vei» — den peker feil vei med hensikt, og
// ANTIDEP_CONSTITUTION.md §9 krever at den bevares. De øvrige punktene, og
// kontrollen av hver enkelt lenkes egen relasjonstype, gjelder alle lenkene.
//
// **Å telle med er ikke det samme som å kunne felles.** En bekreftelse på en
// akse gjelder uansett hvilken lenke det er; et *avvik* krever i tillegg at
// lenken faktisk lovet samsvar på den aksen. Se `promisesCorrespondence`.
//
// ----------------------------------------------------------------------------
// Hva som ikke gjøres her
//
// Modulen henter ingenting og skriver ingenting: den er en ren funksjon av det
// grunnlaget den får. Kildeteksten den sammenligner mot, er hentet og
// fingeravtrykk-kontrollert av `claim-verification-run.ts`, som også avgjør at
// ingenting registreres når grunnlaget ikke lot seg etterprøve.
// ============================================================================

import {
  searchProjections,
  trimNumericText,
  verbatimOccursIn,
  verbatimQuotes,
} from './extraction-checks.ts'
import type { ClaimEvidenceLink, ClaimRevisionInput } from './claim-verification-input.ts'
import type { TextExtractionRecipe } from './document-binding.ts'

/** `workflow.verification_check_result`. */
export type CheckResult = 'ok' | 'deviation' | 'not_assessable'

/** `workflow.verification_outcome`. */
export type ClaimVerificationOutcome = 'verified' | 'needs_correction' | 'rejected' | 'uncertain'

/** De sju kontrollpunktene i DATABASE_ARCHITECTURE.md §30. */
export interface ClaimCheckPoints {
  readonly sourceSupport: CheckResult
  readonly populationMatch: CheckResult
  readonly comparatorMatch: CheckResult
  readonly timeframeMatch: CheckResult
  readonly directionAndMagnitude: CheckResult
  readonly qualifiersComplete: CheckResult
  readonly contradictoryEvidenceRepresented: CheckResult
}

/** Resultatet for én kontrollert evidenslenke. */
export interface ClaimCitationReport {
  readonly claimEvidenceLinkId: string
  readonly sourceVersionId: string
  readonly checkedContentHash: string
  readonly relationshipSupported: CheckResult
  readonly finding: string | null
}

export interface ClaimCheckReport {
  readonly outcome: ClaimVerificationOutcome
  readonly checks: ClaimCheckPoints
  readonly citations: readonly ClaimCitationReport[]
  /** Avvikene og de uavklarte punktene. `null` bare når kontrollen ikke fant noe. */
  readonly findings: string | null
  readonly rationale: string
}

/** Én lenke med den representasjonen kontrollen faktisk fikk se. */
export interface CheckedLink {
  readonly link: ClaimEvidenceLink
  /** Representasjonen, skaffet på nytt og med reprodusert fingeravtrykk. */
  readonly sourceText: string
  /**
   * Oppskriften som gjenskapte teksten, når det **ikke** var den kildeversjonen
   * selv bærer.
   *
   * `null` eller utelatt i det normale tilfellet. Er den satt, er den
   * registrerte oppskriften avløst, og dagens kom fram til nøyaktig det
   * registrerte fingeravtrykket (`source-binding.ts`). Kontrollen fører det i
   * begrunnelsen, slik at et menneske ser hvilken oppskrift som faktisk
   * gjenskapte teksten — «gjenskapt med X, stemmer med fingeravtrykket
   * registrert under Y» er en annen påstand enn «kjørt med den registrerte
   * oppskriften», og de to skal ikke se like ut i ettertid.
   */
  readonly reproducedWith?: TextExtractionRecipe | null
}

export interface ClaimCheckContext {
  readonly revision: ClaimRevisionInput
  readonly links: readonly CheckedLink[]
}

/** Relasjonstypene som betyr at lenken underbygger påstanden. */
const SUPPORTING = new Set(['supports', 'partially_supports'])

/**
 * Om lenken *lover* at påstanden svarer til funnet på hver strukturelle akse.
 *
 * Bare `supports` + `direct` gjør det. De to andre verdiene erklærer selv at de
 * ikke gjør det, og vokabularene sier det med rene ord:
 *
 *   `partially_supports`  «underbygger deler av den, for eksempel retningen men
 *                          ikke størrelsen» — hvilken del som ikke er dekket,
 *                          registreres ikke noe sted
 *   `directness = indirect`  «treffer påstandens populasjon, endepunkt,
 *                          komparator og tidsrom» bare indirekte
 *
 * Et strukturelt avvik på en slik lenke er derfor ikke et bevist avvik: det kan
 * være nettopp grunnen til at lenken er merket som den er. Å melde det som
 * `deviation` ville gjort en korrekt påstand til `needs_correction`, og
 * ødelagt den ene garantien denne kontrollen hviler på — at hvert avvik den
 * melder, er et faktisk avvik (§74.33: en verifikator som roper ulv, er verre
 * enn ingen verifikator).
 *
 * Merk hva predikatet *ikke* gjør: det svekker ingen bekreftelse. Stemmer
 * aksen, er den kontrollert uansett hvilken lenke det gjelder — det er bare et
 * *avvik* som krever at lenken faktisk lovet samsvar.
 */
function promisesCorrespondence(link: ClaimEvidenceLink): boolean {
  return link.relationshipType === 'supports' && link.directness === 'direct'
}

/**
 * Utfallet av en akse som ikke stemmer.
 *
 * Ett sted, fordi regelen er den samme for populasjon, komparator, tidsrom og
 * retning — og fordi en regel skrevet fire ganger er fire steder å glemme den.
 */
function mismatch(checked: CheckedLink, findings: Findings, note: string): CheckResult {
  if (promisesCorrespondence(checked.link)) {
    findings.add(note)
    return 'deviation'
  }
  findings.add(
    `${note} Lenken er ført som ${checked.link.relationshipType}/${checked.link.directness}, ` +
      'og lover derfor ikke samsvar på denne aksen — avviket kan være nettopp det den erkjenner. ' +
      'Om det er akseptabelt, er en faglig vurdering denne kontrollen ikke gjør.',
  )
  return 'not_assessable'
}

// ----------------------------------------------------------------------------
// Tidsrom
//
// `interval` serialiseres av PostgreSQL som «182 days», «8 mons», «1 year 3 days»
// eller «12:00:00». Bare rene dager (eventuelt med en klokkedel) sammenlignes:
// måneder og år har ingen fast lengde, og en tilnærming ville kunnet gi et
// *avvik* som ikke er ett. Alt annet er uavklart, ikke feil.
// ----------------------------------------------------------------------------

/** Antall dager, eller `null` når intervallet ikke lar seg sammenligne eksakt. */
export function intervalDays(value: string | null): number | null {
  if (value === null) {
    return null
  }
  const trimmed = value.trim()
  if (trimmed.length === 0) {
    return null
  }
  const match = /^(?:(-?\d+) days?)?\s*(?:(-?\d{1,}):(\d{2}):(\d{2}(?:\.\d+)?))?$/.exec(trimmed)
  if (match === null) {
    return null
  }
  const [, days, hours, minutes, seconds] = match
  if (days === undefined && hours === undefined) {
    return null
  }
  const fromTime =
    hours === undefined
      ? 0
      : (Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds)) / 86_400
  return (days === undefined ? 0 : Number(days)) + fromTime
}

interface Span {
  readonly min: number
  readonly max: number
}

function span(min: string | null, max: string | null): Span | null {
  const from = intervalDays(min)
  const to = intervalDays(max)
  return from === null || to === null ? null : { min: from, max: to }
}

// ----------------------------------------------------------------------------
// Selve kontrollen
// ----------------------------------------------------------------------------

/**
 * Funnene kontrollen skriver.
 *
 * Både avvik og uavklarte punkter føres opp. En rad som ikke er bekreftet, skal
 * si hva som ikke ble avgjort, der en leser ser etter det — og skillet mellom de
 * to leses av kontrollpunktenes egne verdier, ikke av teksten.
 */
class Findings {
  private readonly notes: string[] = []

  add(text: string): void {
    this.notes.push(text)
  }

  render(): string | null {
    return this.notes.length === 0 ? null : this.notes.map((note) => `- ${note}`).join('\n')
  }
}

function supportingLinks(links: readonly CheckedLink[]): readonly CheckedLink[] {
  return links.filter((checked) => SUPPORTING.has(checked.link.relationshipType))
}

/** Kombinerer per-lenke-resultater: ett avvik feller, ellers avgjør om alt holdt. */
function combine(results: readonly CheckResult[]): CheckResult {
  if (results.length === 0) {
    return 'not_assessable'
  }
  if (results.includes('deviation')) {
    return 'deviation'
  }
  return results.every((result) => result === 'ok') ? 'ok' : 'not_assessable'
}

function checkSourceSupport(
  context: ClaimCheckContext,
  quoteFailures: readonly string[],
  findings: Findings,
): CheckResult {
  const supporting = supportingLinks(context.links)

  if (supporting.length === 0) {
    findings.add(
      'Ingen av de registrerte evidenslenkene underbygger påstanden: alle er ført som ' +
        'contradicts, neutral_contextual eller indirect. En påstand uten en eneste støttende ' +
        'lenke er ikke etterprøvbar slik den er formulert (ANTIDEP_CONSTITUTION.md §4).',
    )
    return 'deviation'
  }

  if (quoteFailures.length > 0) {
    findings.add(
      'Utdrag ekstraksjonen bygger på ble ikke gjenfunnet ordrett i kildeversjonens ' +
        `representasjon: ${quoteFailures.join(', ')}. Grunnlaget påstanden hviler på lar seg ` +
        'dermed ikke etterprøve mot kilden.',
    )
    return 'deviation'
  }

  findings.add(
    'Om ordlyden i påstanden faktisk er dekket av grunnlaget, krever språkforståelse og er ' +
      'ikke avgjort av denne kontrollen. Det som er kontrollert, er at det finnes støttende ' +
      'lenker, og at utdragene de bygger på fortsatt står ordrett i kildeversjonene.',
  )
  return 'not_assessable'
}

function checkPopulation(context: ClaimCheckContext, findings: Findings): CheckResult {
  const claimPopulation = context.revision.claim.populationLabel
  if (claimPopulation === null) {
    findings.add(
      'Påstanden er ikke avgrenset til en registrert populasjon, så det finnes ingen ' +
        'populasjonsangivelse å sammenligne med grunnlaget.',
    )
    return 'not_assessable'
  }

  const results = supportingLinks(context.links).map((checked): CheckResult => {
    const extraction = checked.link.evidenceItem.extraction
    if (extraction.populationAvailability !== 'reported_value') {
      findings.add(
        `Evidensfunnet i lenke ${checked.link.claimEvidenceLinkId} oppgir ingen lest ` +
          `populasjon (${extraction.populationAvailability}), så påstandens populasjon lar seg ` +
          'ikke sammenlignes med den.',
      )
      return 'not_assessable'
    }
    if (extraction.populationLabel === claimPopulation) {
      return 'ok'
    }
    return mismatch(
      checked,
      findings,
      `Lenke ${checked.link.claimEvidenceLinkId} gjelder populasjonen ` +
        `«${String(extraction.populationLabel)}», mens påstanden gjelder «${claimPopulation}».`,
    )
  })

  return combine(results)
}

function comparatorOf(kind: string, drugName: string | null): string {
  return kind === 'drug' ? `drug:${String(drugName)}` : kind
}

function checkComparator(context: ClaimCheckContext, findings: Findings): CheckResult {
  const claim = context.revision.claim
  const wanted = comparatorOf(claim.comparatorKind, claim.comparatorDrugName)

  const results = supportingLinks(context.links).map((checked): CheckResult => {
    const extraction = checked.link.evidenceItem.extraction
    const found = comparatorOf(extraction.comparatorKind, extraction.comparatorDrugName)
    if (found === wanted) {
      return 'ok'
    }
    return mismatch(
      checked,
      findings,
      `Lenke ${checked.link.claimEvidenceLinkId} har komparator «${found}», mens påstanden ` +
        `gjelder «${wanted}». En kontrast mellom to armer er ikke det samme som en endring ` +
        'fra behandlingsstart.',
    )
  })

  return combine(results)
}

function checkTimeframe(context: ClaimCheckContext, findings: Findings): CheckResult {
  const claim = context.revision.claim
  const claimSpan = span(claim.timeframeMin, claim.timeframeMax)
  if (claimSpan === null) {
    findings.add(
      'Påstanden oppgir ikke et tidsrom som lar seg sammenligne eksakt (ingen tidsavgrensning, ' +
        'eller et intervall i måneder eller år, som ikke har fast lengde).',
    )
    return 'not_assessable'
  }

  const results = supportingLinks(context.links).map((checked): CheckResult => {
    const extraction = checked.link.evidenceItem.extraction
    if (extraction.timepointAvailability !== 'reported_value') {
      findings.add(
        `Evidensfunnet i lenke ${checked.link.claimEvidenceLinkId} oppgir ikke noe målt ` +
          `tidspunkt (${extraction.timepointAvailability}).`,
      )
      return 'not_assessable'
    }
    const itemSpan = span(extraction.timepointMin, extraction.timepointMax)
    if (itemSpan === null) {
      findings.add(
        `Tidspunktet i lenke ${checked.link.claimEvidenceLinkId} lar seg ikke sammenlignes ` +
          'eksakt med påstandens tidsrom.',
      )
      return 'not_assessable'
    }
    if (itemSpan.min === claimSpan.min && itemSpan.max === claimSpan.max) {
      return 'ok'
    }
    if (itemSpan.max < claimSpan.min || itemSpan.min > claimSpan.max) {
      return mismatch(
        checked,
        findings,
        `Lenke ${checked.link.claimEvidenceLinkId} måler et tidspunkt som ligger helt utenfor ` +
          'tidsrommet påstanden gjelder for.',
      )
    }
    findings.add(
      `Tidsrommet i påstanden og tidspunktet i lenke ${checked.link.claimEvidenceLinkId} ` +
        'overlapper, men er ikke det samme. Om grunnlaget dekker hele tidsrommet, er en faglig ' +
        'vurdering denne kontrollen ikke gjør.',
    )
    return 'not_assessable'
  })

  return combine(results)
}

function checkDirectionAndMagnitude(context: ClaimCheckContext, findings: Findings): CheckResult {
  const claim = context.revision.claim
  const supporting = supportingLinks(context.links)
  const results: CheckResult[] = []

  if (claim.direction === null) {
    findings.add('Påstanden uttrykker ingen strukturert retning å sammenligne med grunnlaget.')
    results.push('not_assessable')
  } else {
    for (const checked of supporting) {
      const reported = checked.link.evidenceItem.extraction.reportedDirection
      if (reported === 'not_stated') {
        findings.add(
          `Evidensfunnet i lenke ${checked.link.claimEvidenceLinkId} oppgir ingen retning.`,
        )
        results.push('not_assessable')
      } else if (reported !== claim.direction) {
        results.push(
          mismatch(
            checked,
            findings,
            `Lenke ${checked.link.claimEvidenceLinkId} er ført som støttende, men rapporterer ` +
              `retningen «${reported}», mens påstanden konkluderer med «${claim.direction}».`,
          ),
        )
      } else {
        results.push('ok')
      }
    }
  }

  if (claim.magnitudeMeasure !== null) {
    const matched = supporting.some((checked) => {
      const extraction = checked.link.evidenceItem.extraction
      return (
        extraction.estimateAvailability === 'reported_value' &&
        extraction.effectMeasure === claim.magnitudeMeasure &&
        extraction.estimateUnit === claim.magnitudeUnit &&
        extraction.estimate !== null &&
        claim.magnitudeValue !== null &&
        trimNumericText(extraction.estimate) === trimNumericText(claim.magnitudeValue)
      )
    })
    if (matched) {
      results.push('ok')
    } else {
      // Uavklart, aldri et avvik.
      //
      // En påstandsstørrelse trenger ikke være identisk med ett enkelt
      // kildeestimat: en `evidence_synthesis` er nettopp en syntese, og en
      // størrelse kan legitimt ligge mellom flere funn. At ingen enkeltlenke
      // oppgir nøyaktig verdien, beviser derfor ikke at påstanden er mer presis
      // enn grunnlaget — det beviser bare at den ikke lar seg bekrefte
      // deterministisk.
      //
      // Det er samme regel som ekstraksjonskontrollen alt bruker for tall
      // (§74.33): et manglende talltreff gir `uncertain` og ikke et avvik, fordi
      // tallet kan stå skrevet på en form kontrollen ikke gjenkjenner. Funnet
      // står oppført uansett, og `not_assessable` blokkerer publiseringsgaten
      // like effektivt som et avvik ville gjort — det som faller bort, er
      // anklagen, ikke sperren.
      findings.add(
        `Påstanden tallfester størrelsen som ${String(claim.magnitudeValue)} ` +
          `${String(claim.magnitudeUnit ?? '')} (${claim.magnitudeMeasure}), men ingen enkelt ` +
          'støttende evidenslenke oppgir nøyaktig den verdien med det målet og den enheten. ' +
          'Om størrelsen er en forsvarlig syntese av grunnlaget, eller er mer presis enn det ' +
          '(ANTIDEP_CONSTITUTION.md §4, §6), lar seg ikke avgjøre deterministisk.',
      )
      results.push('not_assessable')
    }
  }

  return combine(results)
}

function checkQualifiers(context: ClaimCheckContext, findings: Findings): CheckResult {
  const weakened = context.links.filter(
    (checked) =>
      checked.link.directness === 'indirect' ||
      checked.link.relationshipType === 'partially_supports' ||
      checked.link.relationshipType === 'contradicts',
  )

  if (weakened.length === 0) {
    findings.add(
      'Om påstanden mangler vesentlige forbehold, krever språkforståelse og er ikke avgjort av ' +
        'denne kontrollen.',
    )
    return 'not_assessable'
  }

  const claim = context.revision.claim
  const listed = weakened.map((checked) => checked.link.claimEvidenceLinkId).join(', ')

  // Avvik bare når *ingen* av de to feltene som kan bære et forbehold, er fylt
  // ut. Et forbehold kan stå i `qualifiers` eller i `uncertainty_summary`, og
  // en tom `qualifiers` alene beviser derfor ingenting: teksten kan like gjerne
  // ligge i usikkerhetsvurderingen. Er begge tomme, står det ingen reservasjon
  // noe sted i den strukturerte påstanden, og det er en sikker motsigelse.
  if (claim.qualifiers === null && claim.uncertaintySummary === null) {
    findings.add(
      `Grunnlaget inneholder indirekte, delvis støttende eller motstridende lenker (${listed}), ` +
        'mens påstanden verken oppgir forbehold eller en usikkerhetsvurdering. Da står det ' +
        'ingen reservasjon noe sted (ANTIDEP_CONSTITUTION.md §6).',
    )
    return 'deviation'
  }

  findings.add(
    `Grunnlaget inneholder indirekte, delvis støttende eller motstridende lenker (${listed}). ` +
      'Påstanden oppgir en reservasjon, men om den dekker nettopp det grunnlaget svekker, ' +
      'krever språkforståelse og er ikke avgjort av denne kontrollen.',
  )
  return 'not_assessable'
}

function checkContradictoryEvidence(context: ClaimCheckContext, findings: Findings): CheckResult {
  const unlinked = context.revision.unlinkedRelatedEvidence

  if (unlinked.length > 0) {
    findings.add(
      'Basen inneholder registrerte evidensfunn på samme virkestoff og endepunkt som ikke er ' +
        `lenket til denne revisjonen: ${unlinked
          .map((item) => `${item.evidenceItemId} (${item.sourceTitle})`)
          .join(', ')}. Om de er relevante for påstanden, er en faglig vurdering.`,
    )
  } else {
    findings.add(
      'Ingen registrerte evidensfunn på samme virkestoff og endepunkt står ulenket. Det er ' +
        'ikke det samme som at motstridende forskning ikke finnes: Antidep kjenner bare den ' +
        'evidensen som er registrert (ANTIDEP_CONSTITUTION.md §17).',
    )
  }

  // Aldri `ok`. Se hodekommentaren: fravær av registrert motstridende evidens er
  // ikke fravær av motstridende evidens, og et deterministisk søk i egen base kan
  // ikke svare på annet enn hva basen inneholder.
  return 'not_assessable'
}

/**
 * Kontrollen av én lenkes egen relasjonstype (EVIDENCE_PIPELINE.md §40).
 *
 * Aldri `ok`: at et evidensfunn peker samme vei som påstanden, er ikke det samme
 * som at det støtter den slik den er formulert — og «støtter» skal aldri følge av
 * emnelikhet (§39, ANTIDEP_CONSTITUTION.md §4). Det kontrollen kan avgjøre, er om
 * den registrerte relasjonstypen er *motsagt* av grunnlaget.
 */
function checkCitation(checked: CheckedLink, claimDirection: string | null): ClaimCitationReport {
  const link = checked.link
  const version = link.evidenceItem.sourceVersion
  // Kjøreren registrerer ingenting for en lenke uten etterprøvbar kildeversjon,
  // så begge er satt her. Kastet er en kontraktskontroll og ikke en gren som kan
  // inntreffe i praksis.
  if (version === null || version.contentHash === null) {
    throw new Error(
      `Lenke ${link.claimEvidenceLinkId} mangler kildeversjon eller fingeravtrykk, og skulle ` +
        'aldri nådd kontrollen.',
    )
  }

  const projections = searchProjections(checked.sourceText)
  const missing = verbatimQuotes(link.evidenceItem.extraction.rawExtraction).filter(
    (quote) => !verbatimOccursIn(projections, quote.text),
  )

  if (missing.length > 0) {
    return {
      claimEvidenceLinkId: link.claimEvidenceLinkId,
      sourceVersionId: version.sourceVersionId,
      checkedContentHash: version.contentHash,
      relationshipSupported: 'deviation',
      finding:
        `Utdragene ${missing.map((quote) => quote.key).join(', ')} ble ikke gjenfunnet ordrett ` +
        'i kildeversjonens representasjon. Relasjonen hviler på en gjengivelse som ikke lar seg ' +
        'etterprøve mot kilden.',
    }
  }

  const reported = link.evidenceItem.extraction.reportedDirection
  const directional = claimDirection !== null && reported !== 'not_stated'

  // Bare en lenke som *lover* samsvar kan motsies av retningen. En
  // `partially_supports`-lenke støtter per definisjon bare deler av påstanden,
  // og en indirekte lenke treffer den bare indirekte — en annen retning der kan
  // være nettopp det lenken erkjenner.
  if (directional && promisesCorrespondence(link) && reported !== claimDirection) {
    return {
      claimEvidenceLinkId: link.claimEvidenceLinkId,
      sourceVersionId: version.sourceVersionId,
      checkedContentHash: version.contentHash,
      relationshipSupported: 'deviation',
      finding:
        `Lenken er registrert som supports/direct, men evidensfunnet rapporterer retningen ` +
        `«${reported}», mens påstanden konkluderer med «${String(claimDirection)}».`,
    }
  }

  // Funnteksten sier bare det kontrollen faktisk gjorde. På en lenke som ikke
  // lover samsvar, ble retningen ikke prøvd som en motsigelse i det hele tatt,
  // og «ikke motsagt» ville vært en påstand kontrollen ikke har dekning for.
  const directionNote = promisesCorrespondence(link)
    ? `og relasjonstypen ${link.relationshipType}/${link.directness} er ikke motsagt av den ` +
      'registrerte retningen.'
    : `men lenken er ført som ${link.relationshipType}/${link.directness} og lover ikke samsvar ` +
      'på retningen, så retningen er ikke prøvd som en motsigelse.'

  return {
    claimEvidenceLinkId: link.claimEvidenceLinkId,
    sourceVersionId: version.sourceVersionId,
    checkedContentHash: version.contentHash,
    relationshipSupported: 'not_assessable',
    finding:
      `Utdragene i evidensfunnet står ordrett i kildeversjonen, ${directionNote} ` +
      'Om kilden faktisk støtter denne formuleringen, krever språkforståelse og er ikke avgjort ' +
      'her (EVIDENCE_PIPELINE.md §39).',
  }
}

/**
 * Sier hvilken oppskrift som gjenskapte teksten, når det ikke var radens egen.
 *
 * Tom streng i det normale tilfellet. En kontroll som gjenskapte teksten med en
 * annen oppskrift enn den registrerte, skal si det der et menneske leser
 * begrunnelsen — ikke bare i kjøringens manifest (§74.46).
 */
function reproductionNote(links: readonly CheckedLink[]): string {
  const substituted = links
    .map((checked) => checked.reproducedWith ?? null)
    .filter((recipe): recipe is TextExtractionRecipe => recipe !== null)
  if (substituted.length === 0) {
    return ''
  }
  const recipe = substituted[0] as TextExtractionRecipe
  return (
    ` Minst én kildeversjon bærer en oppskrift som er avløst og ikke lenger kjørbar. Teksten er ` +
    `gjenskapt med «${recipe.tool} ${recipe.arguments}»` +
    (recipe.transform === null ? '' : ` og ${recipe.transform}`) +
    ', som kom fram til nøyaktig det registrerte fingeravtrykket. Oppskriften raden bærer, er ' +
    'ikke skrevet om.'
  )
}

/**
 * Kontrollerer én påstandsrevisjon mot det registrerte evidensgrunnlaget.
 *
 * Ren funksjon: alt som rører omverdenen — hentingen av kildene, sammenligningen
 * av fingeravtrykk — er gjort før kallet.
 */
export function checkClaim(context: ClaimCheckContext): ClaimCheckReport {
  const findings = new Findings()

  const citations = context.links.map((checked) =>
    checkCitation(checked, context.revision.claim.direction),
  )

  const quoteFailures = citations
    .filter((citation) => citation.relationshipSupported === 'deviation')
    .filter((citation) => citation.finding?.startsWith('Utdragene') === true)
    .map((citation) => citation.claimEvidenceLinkId)

  const unverifiedExtractions = context.links.filter(
    (checked) => checked.link.currentExtractionVerification?.outcome !== 'verified',
  )
  if (unverifiedExtractions.length > 0) {
    findings.add(
      'Evidenslenker der den gjeldende ekstraksjonsverifikasjonen ikke bekrefter funnet: ' +
        `${unverifiedExtractions.map((checked) => checked.link.claimEvidenceLinkId).join(', ')}. ` +
        'Publiseringsgatens G4 og G5 stopper uansett på det, og en claim-kontroll av en ' +
        'ukontrollert ekstraksjon er en kontroll av tall ingen har sett mot kilden.',
    )
  }

  const checks: ClaimCheckPoints = {
    sourceSupport: checkSourceSupport(context, quoteFailures, findings),
    populationMatch: checkPopulation(context, findings),
    comparatorMatch: checkComparator(context, findings),
    timeframeMatch: checkTimeframe(context, findings),
    directionAndMagnitude: checkDirectionAndMagnitude(context, findings),
    qualifiersComplete: checkQualifiers(context, findings),
    contradictoryEvidenceRepresented: checkContradictoryEvidence(context, findings),
  }

  const anyDeviation =
    Object.values(checks).includes('deviation') ||
    citations.some((citation) => citation.relationshipSupported === 'deviation')

  const outcome: ClaimVerificationOutcome = anyDeviation ? 'needs_correction' : 'uncertain'

  const rationale =
    (outcome === 'needs_correction'
      ? 'Deterministisk kontroll av påstanden mot det registrerte evidensgrunnlaget: hver ' +
        'evidenslenkes kildeversjon er skaffet på nytt og fingeravtrykket reprodusert, og ' +
        'påstandens strukturerte betydning er sammenlignet felt for felt med grunnlaget. ' +
        'Kontrollen fant minst ett avvik; se funnene.'
      : 'Kontrollen konkluderte ikke, og dette er ikke et avvik. Hver evidenslenkes ' +
        'kildeversjon er skaffet på nytt og fingeravtrykket reprodusert, og påstandens ' +
        'strukturerte betydning er sammenlignet felt for felt med grunnlaget uten at noe avvik ' +
        'ble funnet. En deterministisk kontroll kan ikke avgjøre om ordlyden er dekket, om ' +
        'vesentlige forbehold mangler, eller om det finnes urepresentert motstridende evidens — ' +
        'og fravær av registrert motstridende evidens er ikke fravær av slik evidens ' +
        '(ANTIDEP_CONSTITUTION.md §11, §17). Utfallet er derfor uavklart, ikke bekreftet.') +
    reproductionNote(context.links)

  return { outcome, checks, citations, findings: findings.render(), rationale }
}
