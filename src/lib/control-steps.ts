// ============================================================================
// Stegenes identitet, og avtrykket av det hvert steg faktisk viste
//
// Kontrolløkten er lang. Endrer grunnlaget seg mens den pågår, skal den delen
// som faktisk er endret gjøres om igjen — og bare den. Det krever to ting: at
// hvert steg har en stabil identitet på tvers av en ny henting, og at det finnes
// et avtrykk av nøyaktig det steget viste.
//
// Begge deler ligger her, som rene funksjoner, slik at de kan prøves uten en
// nettleser.
//
// ----------------------------------------------------------------------------
// Avtrykket her er en bekvemmelighet, ikke en garanti
//
// Garantien er databasens: `workflow.assert_extraction_unchanged(uuid, text)` og
// `workflow.assert_evidence_set_unchanged(uuid, text)` avviser en registrering
// der noe som helst i grunnlaget er endret, under radlåsen. Avtrykkene her
// avgjør bare hvor mye kontrolløren må gjøre om igjen etterpå — aldri om noe
// kan registreres.
//
// Derfor er de heller ikke kryptografiske. En sammenligning av det viste
// innholdet, ledd for ledd, er nok til å svare på «viser dette steget fortsatt
// det samme?».
// ============================================================================

import type { ExtractionReviewItem } from './extraction-review'
import type { ClaimRevisionInput } from '../agents/claim-verification-input'

/** Skiller ledd i et avtrykk, med lengdeprefiks slik at de ikke kan gli over i hverandre. */
function joinParts(parts: readonly (string | null)[]): string {
  return parts.map((part) => (part === null ? '|~:' : `|${String(part.length)}:${part}`)).join('')
}

// ----------------------------------------------------------------------------
// Identiteter
// ----------------------------------------------------------------------------

export function claimIntroStepId(): string {
  return 'claim-intro'
}

export function sourceAccessStepId(evidenceItemId: string): string {
  return `source-access:${evidenceItemId}`
}

export function fieldStepId(evidenceItemId: string, field: string): string {
  return `field:${evidenceItemId}:${field}`
}

export function extractionCommitStepId(evidenceItemId: string): string {
  return `extraction-commit:${evidenceItemId}`
}

export function linkStepId(claimEvidenceLinkId: string): string {
  return `link:${claimEvidenceLinkId}`
}

export function checkpointStepId(checkpointKey: string): string {
  return `checkpoint:${checkpointKey}`
}

export function claimCommitStepId(): string {
  return 'claim-commit'
}

export function publicationDecisionStepId(): string {
  return 'publication-decision'
}

export function publicationStepId(): string {
  return 'publication'
}

// ----------------------------------------------------------------------------
// Avtrykk
// ----------------------------------------------------------------------------

/**
 * Avtrykket av hvert steg i kontrollen av én ekstraksjon.
 *
 * Kildetilgangssteget avhenger av kilden og kildeversjonen; et feltsteg av
 * forankringen og av evidensfunnets eget innholdsavtrykk; commit-steget av hele
 * grunnlagsavtrykket, slik at en kontroll registrert av en annen i mellomtiden
 * bare rammer selve registreringen — og ikke svarene kontrolløren allerede har
 * gitt på felter ingenting har skjedd med.
 */
export function extractionStepBasis(item: ExtractionReviewItem): Record<string, string> {
  const { dossier } = item
  const evidenceItemId = dossier.evidenceItemId
  const version = dossier.sourceVersion
  const basis: Record<string, string> = {
    [sourceAccessStepId(evidenceItemId)]: joinParts([
      dossier.sourceStatus,
      version === null ? null : version.sourceVersionId,
      version === null ? null : version.contentHash,
      version === null ? null : version.retrievedFrom,
    ]),
    [extractionCommitStepId(evidenceItemId)]: joinParts([item.extractionDigest]),
  }

  const groundings = new Map(
    dossier.fieldGroundings.map((grounding) => [grounding.checkField, grounding]),
  )
  for (const field of item.requiredCheckFields) {
    const grounding = groundings.get(field) ?? null
    basis[fieldStepId(evidenceItemId, field)] = joinParts([
      dossier.contentHash,
      grounding === null ? null : grounding.fieldGroundingId,
      grounding === null ? null : grounding.sourceExcerpt,
      grounding === null ? null : grounding.sourceLocator,
      grounding === null ? null : grounding.justification,
    ])
  }
  return basis
}

/**
 * Avtrykket av hvert steg i kontrollen av én påstand.
 *
 * De sju kontrollpunktene deler avtrykk: de handler alle om påstanden målt mot
 * hele evidenssettet, og en lenke som kommer til, kan endre svaret på hvert av
 * dem — den nye lenken kan være nettopp den motstridende evidensen kontrollen
 * skulle lete etter (ANTIDEP_CONSTITUTION.md §9).
 *
 * Lenkestegene har sitt eget: en lenke som er uendret, er uendret, selv om en
 * annen er kommet til.
 */
export function claimStepBasis(revision: ClaimRevisionInput): Record<string, string> {
  const shared = joinParts([revision.contentHash, revision.evidenceSetDigest])
  const basis: Record<string, string> = {
    [claimIntroStepId()]: joinParts([revision.contentHash]),
    [claimCommitStepId()]: shared,
  }
  for (const checkpoint of CHECKPOINT_BASIS_KEYS) {
    basis[checkpointStepId(checkpoint)] = shared
  }
  for (const link of revision.links) {
    basis[linkStepId(link.claimEvidenceLinkId)] = joinParts([
      link.relationshipType,
      link.evidenceItem.contentHash,
      link.evidenceItem.sourceTitle,
    ])
  }
  return basis
}

// Nøklene til de sju kontrollpunktene. Ligger her framfor å importeres fra
// vokabularmodulen, slik at avtrykksmodulen ikke drar med seg etikettene.
const CHECKPOINT_BASIS_KEYS = [
  'sourceSupport',
  'populationMatch',
  'comparatorMatch',
  'timeframeMatch',
  'directionAndMagnitude',
  'qualifiersComplete',
  'contradictoryEvidenceRepresented',
] as const
