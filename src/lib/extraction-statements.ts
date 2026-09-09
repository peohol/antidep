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
import { formatIntervalText, renderedText } from './norwegian-format'
import type { VerificationExtraction } from '../agents/verification-input'

/** Ett kontrollfelt, formulert som noe en kliniker kan svare ja eller nei på. */
export interface FieldInterpretation {
  /** Verdien fra `workflow.evidence_check_field` steget gjelder. */
  readonly field: string
  /** Kort overskrift til steget, for eksempel «Antall deltakere». */
  readonly heading: string
  /** Selve utsagnet: «Studien inkluderte 240 deltakere.» */
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
 * Ett punkt når min og maks er like, et intervall når de er forskjellige, og
 * ordrett databaseverdi når PostgreSQL-formen ikke lot seg tolke — aldri
 * ingenting.
 */
function timepointText(extraction: VerificationExtraction): string | null {
  const min = present(extraction.timepointMin)
  const max = present(extraction.timepointMax)
  if (min === null && max === null) {
    return null
  }
  const minText = min === null ? null : renderedText(formatIntervalText(min), 'varighet')
  const maxText = max === null ? null : renderedText(formatIntervalText(max), 'varighet')
  if (minText !== null && maxText !== null) {
    return minText === maxText ? minText : `${minText} til ${maxText}`
  }
  return minText ?? maxText ?? null
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
 */
function availabilityStatement(extraction: VerificationExtraction): {
  readonly statement: string
  readonly detail: string | null
} {
  const pairs: readonly (readonly [string, string, boolean])[] = [
    ['Populasjonen', extraction.populationAvailability, extraction.populationLabel === null],
    ['Antall deltakere', extraction.sampleSizeAvailability, extraction.sampleSize === null],
    ['Tidspunktet', extraction.timepointAvailability, timepointText(extraction) === null],
    ['Estimatet', extraction.estimateAvailability, estimateText(extraction) === null],
    [
      'Konfidensintervallet',
      extraction.confidenceIntervalAvailability,
      confidenceIntervalText(extraction) === null,
    ],
  ]
  const missing = pairs.filter(([, , isAbsent]) => isAbsent)
  if (missing.length === 0) {
    return {
      statement: 'Alle de fem verdifeltene er ført som oppgitt av kilden.',
      detail: null,
    }
  }
  return {
    statement: `Antidep har ført ${String(missing.length)} felt uten verdi, med en begrunnelse for hvert.`,
    detail: missing
      .map(([label, availability]) => `${label}: ${availabilityText(availability)}.`)
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
        statement:
          label === null
            ? `Populasjonen er ikke ført med en verdi: ${availabilityText(extraction.populationAvailability).toLowerCase()}.`
            : `Populasjonen er ${label}.`,
        detail: present(extraction.populationDetail),
      }
    }
    case 'sample_size': {
      const size = extraction.sampleSize
      return {
        ...base,
        statement:
          size === null
            ? `Antall deltakere er ikke ført med en verdi: ${availabilityText(extraction.sampleSizeAvailability).toLowerCase()}.`
            : `Studien inkluderte ${String(size)} deltakere.`,
        detail: null,
      }
    }
    case 'intervention_arm':
      return {
        ...base,
        statement: `Behandlingsarmen er ${extraction.interventionDrugName}.`,
        detail: present(extraction.interventionDetail),
      }
    case 'comparator_arm':
      return {
        ...base,
        statement: comparatorStatement(extraction),
        detail: present(extraction.comparatorDetail),
      }
    case 'outcome':
      return {
        ...base,
        statement: `Endepunktet som måles er ${extraction.outcomeLabel}.`,
        detail: present(extraction.outcomeDetail),
      }
    case 'timepoint': {
      const timepoint = timepointText(extraction)
      return {
        ...base,
        statement:
          timepoint === null
            ? `Tidspunktet er ikke ført med en verdi: ${availabilityText(extraction.timepointAvailability).toLowerCase()}.`
            : `Målingen gjelder ${timepoint} etter oppstart.`,
        detail: null,
      }
    }
    case 'reported_direction':
      return {
        ...base,
        statement: `${termText(readReportedDirection(extraction.reportedDirection), REPORTED_DIRECTION_LABELS, 'retning')}.`,
        detail: null,
      }
    case 'effect_measure': {
      const measure = extraction.effectMeasure
      return {
        ...base,
        statement:
          measure === null
            ? 'Kilden er ikke ført med et effektmål for dette funnet.'
            : `Effekten er målt som ${termText(readEffectMeasure(measure), MEASURE_LABELS, 'effektmål').toLowerCase()}.`,
        detail: null,
      }
    }
    case 'estimate': {
      const estimate = estimateText(extraction)
      return {
        ...base,
        statement:
          estimate === null
            ? `Estimatet er ikke ført med en verdi: ${availabilityText(extraction.estimateAvailability).toLowerCase()}.`
            : `Den målte effekten er ${estimate}.`,
        detail: null,
      }
    }
    case 'confidence_interval': {
      const interval = confidenceIntervalText(extraction)
      return {
        ...base,
        statement:
          interval === null
            ? `Konfidensintervallet er ikke ført med en verdi: ${availabilityText(extraction.confidenceIntervalAvailability).toLowerCase()}.`
            : `Konfidensintervallet er ${interval}.`,
        detail: null,
      }
    }
    case 'availability_semantics': {
      const summary = availabilityStatement(extraction)
      return { ...base, statement: summary.statement, detail: summary.detail }
    }
    case 'limitations': {
      const limitations = present(extraction.limitationsText)
      return {
        ...base,
        statement:
          limitations === null
            ? 'Ingen forbehold er registrert på dette funnet.'
            : 'Antidep har registrert disse forbeholdene ved funnet.',
        detail: limitations,
      }
    }
    case 'source_locator':
      return {
        ...base,
        statement: `Funnet er hentet fra «${extraction.sourceLocator}» i kilden.`,
        detail: null,
      }
    case 'raw_extraction': {
      const raw = rawExtractionText(extraction.rawExtraction)
      return {
        ...base,
        statement:
          raw === null
            ? 'Ingen ordrett gjengivelse fra kilden er bevart ved siden av de strukturerte feltene.'
            : 'Dette er bevart ordrett fra kilden ved siden av de strukturerte feltene.',
        detail: raw,
      }
    }
    default:
      // En feltverdi Antidep ikke kjenner. Den får sitt eget steg framfor å
      // forsvinne: et felt uten spørsmål ville sett ut som et felt uten påstand.
      return {
        ...base,
        statement: `Antidep har en registrert verdi for dette feltet, men kjenner ikke feltet «${field}» og kan ikke formulere den.`,
        detail: null,
      }
  }
}

/** Studiedesignet, som én setning. Vises i innledningen til hvert kildesteg. */
export function designStatement(extraction: VerificationExtraction): string {
  return `Dette er registrert som en ${termText(readStudyDesign(extraction.designCode), STUDY_DESIGN_LABELS, 'studiedesign').toLowerCase()}.`
}
