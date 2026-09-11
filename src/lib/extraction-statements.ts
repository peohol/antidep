// ============================================================================
// Antideps tolkning av ett evidensfunn, ett felt om gangen, som naturlig språk
//
// Kontrolløren skal svare på ett spørsmål per steg: «stemmer denne setningen med
// kilden?». Setningen må derfor være både lettlest og *den samme verdien
// databasen faktisk holder.
//
// ----------------------------------------------------------------------------
// Setningen bygges av den kanoniske raden, ikke av en lagret kopi
//
// Migrasjon 005u lagrer kildeforankringen — utdraget, pekeren og begrunnelsen —
// men bevisst ikke tolkningen. Tolkningen er kolonnene på evidensfunnet, og en
// lagret kopi av dem kunne kommet i utakt med originalen. Da ville kontrolløren
// bekreftet en setning som ikke er det Antidep sier videre
// (ANTIDEP_CONSTITUTION.md §4, §8).
//
// Denne modulen er derfor avledningen: fra de kanoniske feltene til én setning
// per kontrollfelt, deterministisk og uten skjønn.
//
// ----------------------------------------------------------------------------
// Tall gjengis ordrett slik de er lagret
//
// `estimate`, konfidensgrensene og nivået kommer som tekst nettopp for at et
// eksakt desimaltall ikke skal gå veien om en IEEE-754 double
// (`verification-input.ts`). De skrives derfor ut som de står. En lokalisering
// til norsk desimalkomma ville krevd en tolkning av strengen, og det er en
// tolkning for mye i nettopp det steget der kontrolløren sammenligner tegn for
// tegn med kilden.
//
// ----------------------------------------------------------------------------
// Ingen databasefeltnavn og ingen enum-verdier
//
// Klinikeren skal aldri se `sample_size_availability` eller `not_reported`.
// Vokabularene oversettes gjennom de samme oppslagene resten av flaten bruker
// (`vocabulary-labels.ts`), slik at «ikke rapportert i kilden» betyr det samme
// her som i evidensvisningen.
//
// Fravær står som fravær: et felt uten verdi får en setning som sier *hvorfor*
// det ikke har en, aldri en tom setning og aldri en null (§6, §17).
//
// ----------------------------------------------------------------------------
// En tolkning og en mangel er to forskjellige utsagn
//
// Den første reelle kildekontrollen møtte setninger som denne, presentert som
// «Antideps tolkning»:
//
//   «Antidep har ført 1 felt uten verdi, med en begrunnelse for hvert.»
//
// Det er bokføring, ikke et klinisk utsagn en kontrollør kan holde opp mot
// kilden. De to er forskjellige spørsmål, og de skal se forskjellige ut:
//
//   `interpretation`  hva Antidep mener kilden SIER. Spørsmålet er «stemmer
//                     dette med teksten?».
//   `absence`         en opplysning kilden ikke gir, og som Antidep derfor ikke
//                     har ført. Spørsmålet er «stemmer det at kilden ikke
//                     oppgir dette?».
//
// Skillet er `FieldInterpretation.kind`, og flaten stiller det spørsmålet
// utsagnet faktisk inviterer til (`ExtractionFieldStep.tsx`). En manglende verdi
// blir aldri til en klinisk påstand — at et konfidensintervall ikke er
// rapportert, betyr ikke at effekten ikke var signifikant
// (ANTIDEP_CONSTITUTION.md §6, §17).
// ============================================================================

import {
  COMPARATOR_KIND_LABELS,
  EVIDENCE_CHECK_FIELD_LABELS,
  MEASURE_LABELS,
  REPORTED_DIRECTION_LABELS,
  STUDY_DESIGN_LABELS,
  UNIT_LABELS,
  VALUE_AVAILABILITY_LABELS,
  termText,
} from '../components/vocabulary-labels'
import {
  readComparatorKind,
  readEffectMeasure,
  readEstimateUnit,
  readEvidenceCheckField,
  readReportedDirection,
  readStudyDesign,
  readValueAvailability,
} from './evidence-item'
import { formatDurationSpan } from './norwegian-format'
import type { VerificationExtraction } from '../agents/verification-input'

/**
 * Hva slags utsagn steget viser.
 *
 * `interpretation` er hva Antidep mener kilden sier. `absence` er en opplysning
 * kilden ikke gir, og som Antidep derfor ikke har ført — aldri en klinisk
 * påstand utledet av fraværet.
 */
export type FieldStatementKind = 'interpretation' | 'absence'

/** Ett kontrollfelt, formulert som noe en kliniker kan svare ja eller nei på. */
export interface FieldInterpretation {
  /** Verdien fra `workflow.evidence_check_field` steget gjelder. */
  readonly field: string
  /** Kort overskrift til steget, for eksempel «Antall deltakere». */
  readonly heading: string
  /** Om utsagnet er en tolkning av kilden eller en registrert mangel. */
  readonly kind: FieldStatementKind
  /** Selve utsagnet: «Dette estimatet bygger på 240 deltakere.» */
  readonly statement: string
  /**
   * Utdypningen som hører til utsagnet, når ekstraksjonen har en.
   *
   * `null` betyr at ingen utdypning er registrert — ikke at den er tom.
   */
  readonly detail: string | null
}

function availabilityText(value: string): string {
  return termText(readValueAvailability(value), VALUE_AVAILABILITY_LABELS, 'tilgjengelighet')
}

/** Tom eller bare mellomrom er fravær, ikke en verdi. */
function present(value: string | null): string | null {
  if (value === null) {
    return null
  }
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}

/**
 * Tidsrommet som én lesbar varighet.
 *
 * Uker som hovedform når databasens dager går opp i hele uker, med dagene som
 * eksplisitt omregning ved siden av (`norwegian-format.ts`). Kilden til Fava
 * 2000 sier «26 to 32 weeks», og en kontrollør som bare får «182 til 224
 * dager», må regne selv for å se om Antidep gjengir kilden riktig.
 */
function timepointText(extraction: VerificationExtraction): string | null {
  return formatDurationSpan(present(extraction.timepointMin), present(extraction.timepointMax))
}

function estimateText(extraction: VerificationExtraction): string | null {
  const value = present(extraction.estimate)
  if (value === null) {
    return null
  }
  const unit = extraction.estimateUnit
  if (unit === null) {
    return value
  }
  return `${value} ${termText(readEstimateUnit(unit), UNIT_LABELS, 'enhet')}`
}

function confidenceIntervalText(extraction: VerificationExtraction): string | null {
  const lower = present(extraction.ciLower)
  const upper = present(extraction.ciUpper)
  if (lower === null || upper === null) {
    return null
  }
  const level = present(extraction.ciLevelPercent)
  const range = `${lower} til ${upper}`
  return level === null ? range : `${range} (${level} %)`
}

function comparatorStatement(extraction: VerificationExtraction): string {
  const kind = readComparatorKind(extraction.comparatorKind)
  if (kind.kind === 'known' && kind.value === 'none') {
    return `Dette funnet gjelder ${extraction.interventionDrugName} uten en separat sammenligningsarm.`
  }
  if (kind.kind === 'known' && kind.value === 'placebo') {
    return `Sammenligningen er mot placebo.`
  }
  const drug = present(extraction.comparatorDrugName)
  if (drug !== null) {
    return `Sammenligningen er mot ${drug}.`
  }
  return `Sammenligningen er registrert som «${termText(kind, COMPARATOR_KIND_LABELS, 'komparator')}», uten at et virkestoff er oppgitt.`
}

/**
 * Feltene som er ført som «uten verdi», og hvorfor.
 *
 * Dette er kontrollpunktet det er lettest å hoppe over: ingen tall ser galt ut,
 * men «ikke målt» og «ikke rapportert» er to forskjellige påstander om kilden,
 * og begge er påstander (ANTIDEP_CONSTITUTION.md §6).
 *
 * Utsagnet navngir hva som mangler og hvorfor. Det teller dem ikke: «Antidep har
 * ført 1 felt uten verdi» er bokføring, og en kontrollør kan ikke holde et
 * antall opp mot en artikkel.
 */
function availabilityStatement(extraction: VerificationExtraction): {
  readonly kind: FieldStatementKind
  readonly statement: string
  readonly detail: string | null
} {
  const pairs: readonly (readonly [string, string, string, boolean])[] = [
    [
      'Populasjonen',
      'populasjonen funnet gjelder',
      extraction.populationAvailability,
      extraction.populationLabel === null,
    ],
    [
      'Antall deltakere',
      'hvor mange observasjoner estimatet bygger på',
      extraction.sampleSizeAvailability,
      extraction.sampleSize === null,
    ],
    [
      'Tidspunktet',
      'tidspunktet målingen gjelder',
      extraction.timepointAvailability,
      timepointText(extraction) === null,
    ],
    [
      'Estimatet',
      'selve estimatet',
      extraction.estimateAvailability,
      estimateText(extraction) === null,
    ],
    [
      'Konfidensintervallet',
      'et konfidensintervall for estimatet',
      extraction.confidenceIntervalAvailability,
      confidenceIntervalText(extraction) === null,
    ],
  ]
  const missing = pairs.filter(([, , , isAbsent]) => isAbsent)
  if (missing.length === 0) {
    return {
      kind: 'interpretation',
      statement: 'Alle de fem verdifeltene er ført som oppgitt av kilden.',
      detail: null,
    }
  }
  const first = missing[0]
  if (missing.length === 1 && first !== undefined) {
    return {
      kind: 'absence',
      statement: `Antidep har ikke ført ${first[1]}. ${availabilityText(first[2])}.`,
      detail: null,
    }
  }
  return {
    kind: 'absence',
    statement: `Antidep har ikke ført ${missing.map(([, subject]) => subject).join(', ')}.`,
    detail: missing
      .map(([label, , availability]) => `${label}: ${availabilityText(availability)}.`)
      .join(' '),
  }
}

/**
 * Den rå gjengivelsen, som tekst.
 *
 * `rawExtraction` er utypet jsonb med vilje (migrasjon 003), så formen leses som
 * den finnes framfor å kreves. Strengverdiene under objektets nøkler er det en
 * kontrollør skal sammenligne med kilden; nøkkelnavnene er teknikk og utelates.
 */
function rawExtractionText(raw: unknown): string | null {
  if (typeof raw === 'string') {
    return present(raw)
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return null
  }
  const quotes = Object.values(raw as Record<string, unknown>)
    .filter((value): value is string => typeof value === 'string')
    .map(present)
    .filter((value): value is string => value !== null)
  return quotes.length === 0 ? null : quotes.join(' ')
}

/** Et utsagn om hva kilden sier. */
function says(statement: string): {
  readonly kind: FieldStatementKind
  readonly statement: string
} {
  return { kind: 'interpretation', statement }
}

/**
 * En opplysning kilden ikke gir, med den registrerte grunnen.
 *
 * Aldri en klinisk påstand utledet av fraværet: et manglende konfidensintervall
 * betyr ikke at effekten var uten statistisk signifikans, og en flate som skrev
 * det, ville laget en påstand ingen har ført (ANTIDEP_CONSTITUTION.md §6, §17).
 */
function absent(
  subject: string,
  availability: string,
): { readonly kind: FieldStatementKind; readonly statement: string } {
  return {
    kind: 'absence',
    statement: `Antidep har ikke ført ${subject}. ${availabilityText(availability)}.`,
  }
}

/**
 * En mangel uten en egen fraværskolonne å begrunne seg med.
 *
 * Effektmål, forbehold og den rå gjengivelsen har ingen `*_availability`; da
 * står fraværet alene, framfor å låne en begrunnelse fra et annet felt.
 */
function absentWithoutReason(subject: string): {
  readonly kind: FieldStatementKind
  readonly statement: string
} {
  return { kind: 'absence', statement: `Antidep har ikke ført ${subject}.` }
}

/**
 * Utsagnet Antidep gjør om ett kontrollfelt.
 *
 * Ett sted, fordi den samme setningen skal stå likt i kontrolløkten og i en
 * eventuell oppsummering. En ukjent feltverdi får sin egen setning framfor å
 * forsvinne: et felt uten spørsmål ville sett ut som et felt uten påstand.
 */
export function interpretField(
  field: string,
  extraction: VerificationExtraction,
): FieldInterpretation {
  const heading = termText(
    readEvidenceCheckField(field),
    EVIDENCE_CHECK_FIELD_LABELS,
    'kontrollfelt',
  )
  const base = { field, heading } as const

  switch (field) {
    case 'population': {
      const label = present(extraction.populationLabel)
      return {
        ...base,
        ...(label === null
          ? absent('populasjonen dette funnet gjelder', extraction.populationAvailability)
          : says(`Populasjonen er ${label}.`)),
        detail: present(extraction.populationDetail),
      }
    }
    case 'sample_size': {
      const size = extraction.sampleSize
      return {
        ...base,
        // Ikke «Studien inkluderte N deltakere». `sample_size` er antallet
        // observasjoner *dette estimatet* bygger på, ikke studiens
        // totalpopulasjon (migrasjon 003, kolonnekommentaren). Fava 2000
        // randomiserte 284 og 96 til sertralin, mens langtidsresultatet hviler
        // på de 48 som fullførte — og «studien inkluderte 48 deltakere» er
        // ganske enkelt feil om den studien.
        ...(size === null
          ? absent(
              'hvor mange observasjoner dette estimatet bygger på',
              extraction.sampleSizeAvailability,
            )
          : says(`Dette estimatet bygger på ${String(size)} deltakere.`)),
        detail: null,
      }
    }
    case 'intervention_arm':
      return {
        ...base,
        ...says(`Behandlingsarmen er ${extraction.interventionDrugName}.`),
        detail: present(extraction.interventionDetail),
      }
    case 'comparator_arm':
      return {
        ...base,
        ...says(comparatorStatement(extraction)),
        detail: present(extraction.comparatorDetail),
      }
    case 'outcome':
      // Hva som ble MÅLT. Hvordan resultatet er uttrykt, er `effect_measure`,
      // og de to så ut som duplikater i den første kildekontrollen.
      return {
        ...base,
        ...says(`Det målte endepunktet er ${extraction.outcomeLabel}.`),
        detail: present(extraction.outcomeDetail),
      }
    case 'timepoint': {
      const timepoint = timepointText(extraction)
      return {
        ...base,
        ...(timepoint === null
          ? absent('et tidspunkt for målingen', extraction.timepointAvailability)
          : says(`Målingen gjelder ${timepoint} etter oppstart.`)),
        detail: null,
      }
    }
    case 'reported_direction':
      return {
        ...base,
        ...says(
          `${termText(readReportedDirection(extraction.reportedDirection), REPORTED_DIRECTION_LABELS, 'retning')}.`,
        ),
        detail: null,
      }
    case 'effect_measure': {
      // Ikke endepunktet på nytt, men hvordan resultatet er UTTRYKT: hvilken
      // størrelse tallet er, og i hvilken enhet. Endepunktet har sitt eget steg.
      const measure = extraction.effectMeasure
      if (measure === null) {
        return { ...base, ...absentWithoutReason('et effektmål for dette funnet'), detail: null }
      }
      const unit = extraction.estimateUnit
      const unitClause =
        unit === null ? '' : `, oppgitt i ${termText(readEstimateUnit(unit), UNIT_LABELS, 'enhet')}`
      return {
        ...base,
        ...says(
          `Resultatet er uttrykt som ${termText(readEffectMeasure(measure), MEASURE_LABELS, 'effektmål').toLowerCase()}${unitClause}.`,
        ),
        detail: null,
      }
    }
    case 'estimate': {
      const estimate = estimateText(extraction)
      return {
        ...base,
        ...(estimate === null
          ? absent('et estimat for dette funnet', extraction.estimateAvailability)
          : says(`Den målte effekten er ${estimate}.`)),
        detail: null,
      }
    }
    case 'confidence_interval': {
      const interval = confidenceIntervalText(extraction)
      return {
        ...base,
        ...(interval === null
          ? absent(
              'et konfidensintervall for dette estimatet',
              extraction.confidenceIntervalAvailability,
            )
          : says(`Konfidensintervallet er ${interval}.`)),
        detail: null,
      }
    }
    case 'availability_semantics': {
      const summary = availabilityStatement(extraction)
      return { ...base, kind: summary.kind, statement: summary.statement, detail: summary.detail }
    }
    case 'limitations': {
      const limitations = present(extraction.limitationsText)
      return {
        ...base,
        ...(limitations === null
          ? absentWithoutReason('noen forbehold ved dette funnet')
          : says('Antidep har registrert disse forbeholdene ved funnet.')),
        detail: limitations,
      }
    }
    case 'source_locator':
      return {
        ...base,
        ...says(`Funnet er hentet fra «${extraction.sourceLocator}» i kilden.`),
        detail: null,
      }
    case 'raw_extraction': {
      const raw = rawExtractionText(extraction.rawExtraction)
      return {
        ...base,
        ...(raw === null
          ? absentWithoutReason('noen ordrett gjengivelse ved siden av de strukturerte feltene')
          : says('Dette er bevart ordrett fra kilden ved siden av de strukturerte feltene.')),
        detail: raw,
      }
    }
    default:
      // En feltverdi Antidep ikke kjenner. Den får sitt eget steg framfor å
      // forsvinne: et felt uten spørsmål ville sett ut som et felt uten påstand.
      return {
        ...base,
        ...says(
          `Antidep har en registrert verdi for dette feltet, men kjenner ikke feltet «${field}» og kan ikke formulere den.`,
        ),
        detail: null,
      }
  }
}

/**
 * Hva kontrolløren faktisk skal kontrollere, som én setning.
 *
 * Bygget av den kanoniske raden — virkestoffet, endepunktet og populasjonen —
 * og ikke av fri KI-tekst. Den står øverst i kontrolløkten, før første
 * delkontroll, fordi den første reelle kildekontrollen begynte med spørsmål om
 * enkeltfelter uten at noe hadde sagt hva saken var
 * (PRODUCT_INFORMATION_ARCHITECTURE.md §63.1).
 *
 * Populasjonen føyes til når en er koblet, og utelates ellers: en setning som
 * påsto en populasjon funnet ikke har, ville vært en påstand flaten fant på.
 */
export function controlSubjectStatement(extraction: VerificationExtraction): string {
  const population = present(extraction.populationLabel)
  const where = population === null ? '' : ` hos ${population}`
  return (
    `Du skal nå kontrollere Antideps vurdering av hva kilden sier om ` +
    `${extraction.outcomeLabel} ved bruk av ${extraction.interventionDrugName}${where}.`
  )
}

/** Studiedesignet, som én setning. Vises i innledningen til hvert kildesteg. */
export function designStatement(extraction: VerificationExtraction): string {
  return `Dette er registrert som en ${termText(readStudyDesign(extraction.designCode), STUDY_DESIGN_LABELS, 'studiedesign').toLowerCase()}.`
}
