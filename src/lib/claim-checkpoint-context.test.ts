// ============================================================================
// Grunnlaget hvert kontrollpunkt faktisk trenger
//
// Den bærende påstanden er avgrensningen: et punkt om tidsrom skal vise
// tidsrommet, ikke hele dossieret. Den andre er at fravær står som fravær — et
// punkt der påstanden ikke sier noe, skal si nettopp det.
// ============================================================================

import { describe, expect, it } from 'vitest'
import { checkpointContext } from './claim-checkpoint-context'
import { claimRevisionFixture } from '../agents/test-support'

describe('checkpointContext', () => {
  it('stiller populasjonen i påstanden opp mot populasjonen i grunnlaget', () => {
    const context = checkpointContext('populationMatch', claimRevisionFixture())
    expect(context.claimSide.join(' ')).toContain('Påstanden gjelder')
    expect(context.evidenceSide.join(' ')).toContain('Populasjonen er')
  })

  it('sier at påstanden ikke er tidsavgrenset framfor å vise en tom linje', () => {
    const context = checkpointContext(
      'timeframeMatch',
      claimRevisionFixture({ claim: { timeframeMin: null, timeframeMax: null } }),
    )
    expect(context.claimSide).toEqual(['Påstanden er ikke tidsavgrenset.'])
  })

  it('sier at påstanden ikke har forbehold framfor å utelate punktet', () => {
    const context = checkpointContext(
      'qualifiersComplete',
      claimRevisionFixture({ claim: { qualifiers: null, uncertaintySummary: null } }),
    )
    expect(context.claimSide[0]).toBe('Påstanden har ingen registrerte forbehold.')
  })

  // ANTIDEP_CONSTITUTION.md §17: fravær av registrert evidens er aldri bevist
  // fravær av evidens, og setningen må si det.
  it('sier at en tom liste over urepresentert evidens ikke betyr at den ikke finnes', () => {
    const context = checkpointContext(
      'contradictoryEvidenceRepresented',
      claimRevisionFixture({ unlinkedRelatedEvidence: [] }),
    )
    expect(context.evidenceSide.join(' ')).toContain('Det betyr ikke at de ikke finnes.')
  })

  it('navngir de funnene som ikke er lenket til påstanden', () => {
    const context = checkpointContext(
      'contradictoryEvidenceRepresented',
      claimRevisionFixture({
        unlinkedRelatedEvidence: [
          {
            evidenceItemId: '00000000-0000-4000-8000-000000000010',
            sourceTitle: 'Testkilde C',
            sourceStatus: 'active',
            interventionDrugName: 'virkestoff a',
            outcomeLabel: 'vektendring',
            reportedDirection: 'decrease',
            effectMeasure: null,
            estimate: null,
            estimateUnit: null,
            createdByActorKey: 'human:testredaktør',
          },
        ],
      }),
    )
    expect(context.evidenceSide.join(' ')).toContain('Testkilde C')
  })

  it('gir et ukjent kontrollpunkt sin egen setning framfor et tomt oppsett', () => {
    const context = checkpointContext('noeHeltNytt', claimRevisionFixture())
    expect(context.claimSide[0]).toContain('kjenner ikke dette kontrollpunktet')
  })
})
