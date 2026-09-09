// ============================================================================
// Hva kontrolløren trenger å se for å svare på ett av de sju kontrollpunktene
//
// De sju punktene i DATABASE_ARCHITECTURE.md §30 er fortsatt de autoritative
// kontrollpunktene. Det som er nytt, er at hvert av dem stilles for seg — og da
// skal bare det grunnlaget punktet faktisk handler om, være synlig.
//
// «Er tidsrommet i påstanden dekket av grunnlaget?» besvares av påstandens
// tidsrom og funnenes tidspunkter. Å vise hele dossieret i det steget ville
// gjort spørsmålet vanskeligere å svare på, ikke lettere
// (ANTIDEP_CONSTITUTION.md §2).
//
// ----------------------------------------------------------------------------
// To sider, alltid
//
// Venstre side er hva Antidep sier i påstanden; høyre side er hva grunnlaget
// faktisk inneholder. Kontrollen er sammenligningen mellom dem, og formen gjør
// den sammenligningen til det den er.
//
// Fravær står som fravær. Et punkt der påstanden ikke sier noe, får setningen
// «Påstanden sier ingenting om dette» — aldri en tom linje, som ville sett ut
// som at det ikke var noe å kontrollere (§6, §17).
// ============================================================================

import {
  COMPARATOR_KIND_LABELS,
  MEASURE_LABELS,
  UNIT_LABELS,
  termText,
} from '../components/vocabulary-labels'
import { readComparatorKind, readEffectMeasure, readEstimateUnit } from './evidence-item'
import { describeClaimDirection, type ClaimDirectionState } from './claim-effect'
import { interpretField } from './extraction-statements'
import { formatIntervalText, renderedText } from './norwegian-format'
import type { ClaimEvidenceLink, ClaimRevisionInput } from '../agents/claim-verification-input'

/** De to sidene av ett kontrollpunkt. */
export interface CheckpointContext {
  /** Hva påstanden sier. Aldri tom: fravær har sin egen setning. */
  readonly claimSide: readonly string[]
  /** Hva grunnlaget inneholder, ett punkt per evidenslenke der det er relevant. */
  readonly evidenceSide: readonly string[]
}

function present(value: string | null): string | null {
  if (value === null) {
    return null
  }
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}

function intervalText(min: string | null, max: string | null): string | null {
  const from = present(min)
  const to = present(max)
  if (from === null && to === null) {
    return null
  }
  const fromText = from === null ? null : renderedText(formatIntervalText(from), 'varighet')
  const toText = to === null ? null : renderedText(formatIntervalText(to), 'varighet')
  if (fromText !== null && toText !== null) {
    return fromText === toText ? fromText : `${fromText} til ${toText}`
  }
  return fromText ?? toText ?? null
}

/**
 * Retningen påstanden uttrykker, som en setning.
 *
 * De samme fem tilstandene `ClaimDirectionState` har, men formulert som utsagn
 * framfor som etiketter: i et kontrollsteg står linjen alene, og «Økning» alene
 * sier ikke hva som øker. `not_expressed` og `no_clear_difference` er og blir to
 * forskjellige ting — det ene er ikke et resultat, det andre er det.
 */
function directionSentence(direction: ClaimDirectionState): string {
  switch (direction.kind) {
    case 'increase':
      return 'Påstanden konkluderer med en økning.'
    case 'decrease':
      return 'Påstanden konkluderer med en reduksjon.'
    case 'no_clear_difference':
      return 'Påstanden konkluderer med at grunnlaget ikke viser en klar forskjell.'
    case 'not_expressed':
      return 'Påstanden angir ingen retning.'
    case 'unknown':
      return `Påstanden angir en retning Antidep ikke kjenner («${direction.rawDirection}»).`
  }
}

function comparatorText(kind: string, drugName: string | null): string {
  const read = readComparatorKind(kind)
  if (read.kind === 'known' && read.value === 'drug') {
    return drugName === null ? 'Et annet virkestoff, uten at det er navngitt' : drugName
  }
  return termText(read, COMPARATOR_KIND_LABELS, 'komparator')
}

function fieldStatementFor(link: ClaimEvidenceLink, field: string): string {
  const interpretation = interpretField(field, link.evidenceItem.extraction)
  return `${link.evidenceItem.sourceTitle}: ${interpretation.statement}`
}

/**
 * Grunnlaget for ett kontrollpunkt.
 *
 * Setningene om evidensfunnene bygges av `interpretField(...)` — de samme
 * setningene kontrolløren allerede har bekreftet mot kilden i feltkontrollen.
 * En annen formulering her ville latt de to stegene beskrive det samme funnet
 * ulikt, og kontrolløren ville ikke visst hvilken hen bekreftet.
 */
export function checkpointContext(
  checkpointKey: string,
  revision: ClaimRevisionInput,
): CheckpointContext {
  const { claim, links } = revision

  switch (checkpointKey) {
    case 'sourceSupport':
      return {
        claimSide: [claim.statement],
        evidenceSide: links.map(
          (link) =>
            `${link.evidenceItem.sourceTitle}: ${interpretField('reported_direction', link.evidenceItem.extraction).statement} ${interpretField('estimate', link.evidenceItem.extraction).statement}`,
        ),
      }
    case 'populationMatch': {
      const population = present(claim.populationLabel)
      const scope = present(claim.scope)
      return {
        claimSide: [
          population === null
            ? 'Påstanden er ikke knyttet til en registrert populasjon.'
            : `Påstanden gjelder ${population}.`,
          scope === null ? 'Ingen anvendelsesområde er registrert.' : scope,
        ],
        evidenceSide: links.map((link) => fieldStatementFor(link, 'population')),
      }
    }
    case 'comparatorMatch':
      return {
        claimSide: [
          `Påstanden sammenligner mot: ${comparatorText(claim.comparatorKind, claim.comparatorDrugName)}.`,
        ],
        evidenceSide: links.map((link) => fieldStatementFor(link, 'comparator_arm')),
      }
    case 'timeframeMatch': {
      const timeframe = intervalText(claim.timeframeMin, claim.timeframeMax)
      return {
        claimSide: [
          timeframe === null
            ? 'Påstanden er ikke tidsavgrenset.'
            : `Påstanden gjelder ${timeframe}.`,
        ],
        evidenceSide: links.map((link) => fieldStatementFor(link, 'timepoint')),
      }
    }
    case 'directionAndMagnitude': {
      const direction = describeClaimDirection(claim.direction)
      const measure = claim.magnitudeMeasure
      const value = present(claim.magnitudeValue)
      const unit = claim.magnitudeUnit
      const magnitude =
        value === null
          ? 'Påstanden oppgir ingen tallstørrelse.'
          : `Påstanden oppgir ${value}${unit === null ? '' : ` ${termText(readEstimateUnit(unit), UNIT_LABELS, 'enhet')}`}` +
            `${measure === null ? '' : ` som ${termText(readEffectMeasure(measure), MEASURE_LABELS, 'effektmål').toLowerCase()}`}.`
      return {
        claimSide: [directionSentence(direction), magnitude],
        evidenceSide: links.flatMap((link) => [
          fieldStatementFor(link, 'reported_direction'),
          fieldStatementFor(link, 'estimate'),
          fieldStatementFor(link, 'confidence_interval'),
        ]),
      }
    }
    case 'qualifiersComplete': {
      const qualifiers = present(claim.qualifiers)
      const uncertainty = present(claim.uncertaintySummary)
      return {
        claimSide: [
          qualifiers === null ? 'Påstanden har ingen registrerte forbehold.' : qualifiers,
          uncertainty === null ? 'Ingen oppsummering av usikkerheten er registrert.' : uncertainty,
        ],
        evidenceSide: links.map((link) => fieldStatementFor(link, 'limitations')),
      }
    }
    case 'contradictoryEvidenceRepresented': {
      const contradicting = links.filter((link) => link.relationshipType === 'contradicts')
      return {
        claimSide: [
          contradicting.length === 0
            ? 'Ingen av de registrerte lenkene er ført som motstridende.'
            : `${String(contradicting.length)} av lenkene er ført som motstridende.`,
        ],
        evidenceSide:
          revision.unlinkedRelatedEvidence.length === 0
            ? [
                'Antidep har ikke registrert andre funn på samme virkestoff og endepunkt. Det betyr ikke at de ikke finnes.',
              ]
            : revision.unlinkedRelatedEvidence.map(
                (evidence) =>
                  `Ikke lenket til påstanden: ${evidence.sourceTitle} (${evidence.interventionDrugName}, ${evidence.outcomeLabel}).`,
              ),
      }
    }
    default:
      return {
        claimSide: ['Antidep kjenner ikke dette kontrollpunktet og kan ikke stille det opp.'],
        evidenceSide: [],
      }
  }
}
