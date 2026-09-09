// ============================================================================
// Avtrykket av det hvert steg viste
//
// Påstandene her er hva som *skal* nullstille et steg, og hva som ikke skal.
// Feil vei begge veier har en pris: nullstilles for mye, gjør kontrolløren om
// igjen arbeid som fortsatt gjelder; nullstilles for lite, står et svar igjen
// som gjelder noe annet enn det som nå vises.
// ============================================================================

import { describe, expect, it } from 'vitest'
import {
  claimStepBasis,
  extractionStepBasis,
  fieldStepId,
  extractionCommitStepId,
  sourceAccessStepId,
  checkpointStepId,
  linkStepId,
} from './control-steps'
import {
  claimRevisionFixture,
  sourceVersionFixture,
  verificationItemFixture,
} from '../agents/test-support'
import type { ExtractionReviewItem } from './extraction-review'

function reviewItem(overrides: Partial<ExtractionReviewItem> = {}): ExtractionReviewItem {
  return {
    dossier: verificationItemFixture({
      sourceVersion: sourceVersionFixture(),
      fieldGroundings: [
        {
          fieldGroundingId: 'g-1',
          checkField: 'outcome',
          sourceExcerpt: 'Weight change was the primary outcome.',
          sourceLocator: 'Metode, avsnitt 2',
          justification: 'Endepunktet er navngitt i metodeavsnittet.',
          createdAt: '2026-09-01T00:00:00+00:00',
          createdByActorId: '99999999-9999-4999-8999-999999999999',
        },
      ],
    }),
    extractionDigest: 'sha256-v1:aaa',
    requiredCheckFields: ['outcome', 'estimate'],
    coveredCheckFields: [],
    currentExtractionVerificationId: null,
    extractionVerifications: [],
    linkedClaimRevisions: [],
    ...overrides,
  }
}

describe('extractionStepBasis', () => {
  it('gir hvert steg sitt eget avtrykk', () => {
    const item = reviewItem()
    const basis = extractionStepBasis(item)
    const id = item.dossier.evidenceItemId
    expect(Object.keys(basis).sort()).toEqual(
      [
        sourceAccessStepId(id),
        extractionCommitStepId(id),
        fieldStepId(id, 'outcome'),
        fieldStepId(id, 'estimate'),
      ].sort(),
    )
  })

  it('endrer feltets avtrykk når forankringen endres, og bare det feltets', () => {
    const before = extractionStepBasis(reviewItem())
    const after = extractionStepBasis(
      reviewItem({
        dossier: verificationItemFixture({
          sourceVersion: sourceVersionFixture(),
          fieldGroundings: [
            {
              fieldGroundingId: 'g-1',
              checkField: 'outcome',
              sourceExcerpt: 'Et helt annet utdrag.',
              sourceLocator: 'Metode, avsnitt 2',
              justification: 'Endepunktet er navngitt i metodeavsnittet.',
              createdAt: '2026-09-01T00:00:00+00:00',
              createdByActorId: '99999999-9999-4999-8999-999999999999',
            },
          ],
        }),
      }),
    )
    const id = reviewItem().dossier.evidenceItemId
    expect(after[fieldStepId(id, 'outcome')]).not.toBe(before[fieldStepId(id, 'outcome')])
    expect(after[fieldStepId(id, 'estimate')]).toBe(before[fieldStepId(id, 'estimate')])
    expect(after[sourceAccessStepId(id)]).toBe(before[sourceAccessStepId(id)])
  })

  it('endrer kildetilgangens avtrykk når kildens status endres', () => {
    const before = extractionStepBasis(reviewItem())
    const after = extractionStepBasis(
      reviewItem({
        dossier: verificationItemFixture({
          sourceStatus: 'retracted',
          sourceVersion: sourceVersionFixture(),
          fieldGroundings: [],
        }),
      }),
    )
    const id = reviewItem().dossier.evidenceItemId
    expect(after[sourceAccessStepId(id)]).not.toBe(before[sourceAccessStepId(id)])
  })

  // Kommer det en kontroll til mens økten pågår, endres grunnlagsavtrykket — og
  // det er registreringssteget som må gjøres om igjen, ikke feltsvarene.
  it('rammer bare registreringssteget når kontrollhistorikken endres', () => {
    const before = extractionStepBasis(reviewItem())
    const after = extractionStepBasis(reviewItem({ extractionDigest: 'sha256-v1:bbb' }))
    const id = reviewItem().dossier.evidenceItemId
    expect(after[extractionCommitStepId(id)]).not.toBe(before[extractionCommitStepId(id)])
    expect(after[fieldStepId(id, 'outcome')]).toBe(before[fieldStepId(id, 'outcome')])
  })

  // Lengdeprefikset skiller ledd som ellers ville flytt over i hverandre.
  it('skiller et manglende ledd fra et tomt ledd', () => {
    const withGrounding = extractionStepBasis(reviewItem())
    const withoutGrounding = extractionStepBasis(
      reviewItem({
        dossier: verificationItemFixture({
          sourceVersion: sourceVersionFixture(),
          fieldGroundings: [],
        }),
      }),
    )
    const id = reviewItem().dossier.evidenceItemId
    expect(withoutGrounding[fieldStepId(id, 'outcome')]).not.toBe(
      withGrounding[fieldStepId(id, 'outcome')],
    )
  })
})

describe('claimStepBasis', () => {
  it('lar de sju kontrollpunktene dele avtrykk, fordi de deler grunnlag', () => {
    const basis = claimStepBasis(claimRevisionFixture())
    expect(basis[checkpointStepId('sourceSupport')]).toBe(
      basis[checkpointStepId('contradictoryEvidenceRepresented')],
    )
  })

  it('gir hver evidenslenke sitt eget avtrykk', () => {
    const revision = claimRevisionFixture()
    const first = revision.links[0]
    expect(first).toBeDefined()
    const basis = claimStepBasis(revision)
    expect(basis[linkStepId(first?.claimEvidenceLinkId ?? '')]).toBeDefined()
  })

  it('endrer de sju punktenes avtrykk når evidenssettet endres', () => {
    const before = claimStepBasis(claimRevisionFixture())
    const after = claimStepBasis(claimRevisionFixture({ evidenceSetDigest: 'sha256-v1:endret' }))
    expect(after[checkpointStepId('populationMatch')]).not.toBe(
      before[checkpointStepId('populationMatch')],
    )
  })
})
