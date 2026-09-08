import { describe, expect, it } from 'vitest'

import { checkClaim, intervalDays, type ClaimCheckContext } from './claim-checks'
import type { ClaimEvidenceLink } from './claim-verification-input'
import { FIXTURE_SOURCE_TEXT, claimEvidenceLinkFixture, claimRevisionFixture } from './test-support'

/**
 * Den positive kontrollen: påstanden stemmer med evidensfunnet på hvert felt
 * kontrollen kan sammenligne, og utdragene står ordrett i kilden.
 *
 * Selv da er utfallet `uncertain`, og det er ikke en mangel — det er hele
 * poenget med asymmetrien: en deterministisk kontroll kan avkrefte, men ikke
 * bekrefte at ordlyden er dekket eller at ingen motstridende evidens mangler.
 */
function context(links: readonly ClaimEvidenceLink[], revisionOverrides = {}): ClaimCheckContext {
  return {
    revision: claimRevisionFixture({ links, ...revisionOverrides }),
    links: links.map((link) => ({ link, sourceText: FIXTURE_SOURCE_TEXT })),
  }
}

describe('checkClaim — den positive kontrollen', () => {
  it('konkluderer ikke, og sier hvorfor', () => {
    const report = checkClaim(context([claimEvidenceLinkFixture()]))

    expect(report.outcome).toBe('uncertain')
    expect(report.rationale).toContain('Kontrollen konkluderte ikke, og dette er ikke et avvik')
  })

  it('kan aldri bekrefte: motstridende evidens lar seg ikke utelukke fra basen alene', () => {
    // ANTIDEP_CONSTITUTION.md §17. Punktet er alltid uavklart, og
    // claim_verifications_verified_requires_all_ok_check gjør dermed `verified`
    // uoppnåelig for denne kontrollen — det er en egenskap ved kontrollen, ikke
    // en feil som skal rettes.
    const report = checkClaim(context([claimEvidenceLinkFixture()]))

    expect(report.checks.contradictoryEvidenceRepresented).toBe('not_assessable')
    expect(Object.values(report.checks)).not.toContain('deviation')
  })

  it('fører populasjon, komparator og retning som kontrollert når de stemmer', () => {
    const report = checkClaim(context([claimEvidenceLinkFixture()]))

    expect(report.checks.populationMatch).toBe('ok')
    expect(report.checks.comparatorMatch).toBe('ok')
    expect(report.checks.directionAndMagnitude).toBe('ok')
  })

  it('lar aldri en enkelt lenke stå som bekreftet støtte', () => {
    // EVIDENCE_PIPELINE.md §39: emnelikhet er ikke støtte. At kilden peker samme
    // vei, er ikke det samme som at den underbygger denne formuleringen.
    const report = checkClaim(context([claimEvidenceLinkFixture()]))

    expect(report.citations).toHaveLength(1)
    expect(report.citations[0]?.relationshipSupported).toBe('not_assessable')
  })
})

describe('checkClaim — det kontrollen faktisk kan falsifisere', () => {
  it('feller en støttende lenke som rapporterer motsatt retning', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          evidenceItem: { extraction: { reportedDirection: 'decrease' } },
        }),
      ]),
    )

    expect(report.outcome).toBe('needs_correction')
    expect(report.checks.directionAndMagnitude).toBe('deviation')
    expect(report.citations[0]?.relationshipSupported).toBe('deviation')
  })

  it('feller ikke en contradicts-lenke som peker samme vei som påstanden', () => {
    // En lenke kan motsi påstanden på størrelsen framfor på retningen: et funn
    // som rapporterer «økning», men en langt mindre økning enn påstanden
    // hevder, er fortsatt motstridende. Retningen alene beviser derfor ikke at
    // relasjonstypen er feil.
    //
    // Den støttende lenken er med for å isolere nettopp det: uten den ville
    // kontrollen felt på at ingen lenke i det hele tatt underbygger påstanden,
    // og den regelen er en annen.
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture(),
        claimEvidenceLinkFixture({
          claimEvidenceLinkId: '53000000-0000-4000-8000-000000000002',
          relationshipType: 'contradicts',
        }),
      ]),
    )

    expect(report.citations[1]?.relationshipSupported).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('feller en påstand uten en eneste støttende lenke', () => {
    const report = checkClaim(
      context([claimEvidenceLinkFixture({ relationshipType: 'neutral_contextual' })]),
    )

    expect(report.checks.sourceSupport).toBe('deviation')
    expect(report.findings).toContain('Ingen av de registrerte evidenslenkene underbygger')
  })

  it('feller en komparator som ikke er den påstanden gjelder', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          evidenceItem: { extraction: { comparatorKind: 'placebo' } },
        }),
      ]),
    )

    expect(report.checks.comparatorMatch).toBe('deviation')
    expect(report.outcome).toBe('needs_correction')
  })

  it('feller en direkte lenke som gjelder en annen populasjon', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          evidenceItem: { extraction: { populationLabel: 'healthy volunteers' } },
        }),
      ]),
    )

    expect(report.checks.populationMatch).toBe('deviation')
  })

  it('lar et erkjent avvik i en indirekte lenke stå uavklart framfor som avvik', () => {
    // Lenken sier selv at den treffer indirekte. Om indirektheten er akseptabel,
    // er en faglig vurdering — kontrollen skal ikke rope ulv om et avvik som
    // allerede er ført opp.
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          directness: 'indirect',
          evidenceItem: { extraction: { populationLabel: 'healthy volunteers' } },
        }),
      ]),
    )

    expect(report.checks.populationMatch).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('feller ikke en påstandsstørrelse som ikke finnes identisk i noe enkelt funn', () => {
    // En evidenssyntese er nettopp en syntese: størrelsen kan legitimt ligge
    // mellom flere funn, og at ingen enkeltlenke oppgir nøyaktig verdien beviser
    // derfor ikke at påstanden er mer presis enn grunnlaget. Samme regel som
    // ekstraksjonskontrollen bruker for tall (§74.33).
    const report = checkClaim(
      context([claimEvidenceLinkFixture()], {
        claim: { magnitudeMeasure: 'mean_change', magnitudeValue: '2.5', magnitudeUnit: 'kg' },
      }),
    )

    expect(report.checks.directionAndMagnitude).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('lar seg ikke avgjøre deterministisk')
  })

  it('feller ikke en syntetisert størrelse som ligger mellom to funn', () => {
    const report = checkClaim(
      context(
        [
          claimEvidenceLinkFixture({
            evidenceItem: { extraction: { estimate: '1.2' } },
          }),
          claimEvidenceLinkFixture({
            claimEvidenceLinkId: '53000000-0000-4000-8000-000000000002',
            evidenceItem: { extraction: { estimate: '1.8' } },
          }),
        ],
        {
          claim: { magnitudeMeasure: 'mean_change', magnitudeValue: '1.5', magnitudeUnit: 'kg' },
        },
      ),
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.checks.directionAndMagnitude).toBe('not_assessable')
  })

  it('godtar en tallfestet størrelse som står nøyaktig slik i grunnlaget', () => {
    const report = checkClaim(
      context([claimEvidenceLinkFixture()], {
        // Fiksturens evidensfunn oppgir 1.5 kg som mean_change. Etterfølgende
        // nuller er samme tall, og skal ikke felle sammenligningen.
        claim: { magnitudeMeasure: 'mean_change', magnitudeValue: '1.50', magnitudeUnit: 'kg' },
      }),
    )

    expect(report.checks.directionAndMagnitude).toBe('ok')
  })

  it('feller et grunnlag der ingen reservasjon står noe sted', () => {
    // Både `qualifiers` og `uncertainty_summary` kan bære forbeholdet. Bare når
    // begge er tomme, er det sikkert at ingen reservasjon er registrert.
    const report = checkClaim(
      context([claimEvidenceLinkFixture({ directness: 'indirect' })], {
        claim: { qualifiers: null, uncertaintySummary: null },
      }),
    )

    expect(report.checks.qualifiersComplete).toBe('deviation')
  })

  it('feller ikke et tomt qualifiers-felt når usikkerheten er beskrevet', () => {
    const report = checkClaim(
      context([claimEvidenceLinkFixture({ directness: 'indirect' })], {
        claim: { qualifiers: null, uncertaintySummary: 'Grunnlaget er indirekte.' },
      }),
    )

    expect(report.checks.qualifiersComplete).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('feller et utdrag som ikke lenger står ordrett i kildeversjonen', () => {
    const report = checkClaim({
      revision: claimRevisionFixture({ links: [claimEvidenceLinkFixture()] }),
      links: [
        {
          link: claimEvidenceLinkFixture(),
          sourceText: 'En helt annen tekst enn den ekstraksjonen siterte fra.',
        },
      ],
    })

    expect(report.checks.sourceSupport).toBe('deviation')
    expect(report.citations[0]?.relationshipSupported).toBe('deviation')
    expect(report.outcome).toBe('needs_correction')
  })
})

describe('checkClaim — bare en lenke som lover samsvar, kan motsies', () => {
  // `partially_supports` underbygger per definisjon bare deler av påstanden, og
  // `directness = indirect` treffer den bare indirekte. Hvilken akse som ikke er
  // dekket, registreres ikke — så en forskjell der er uavklart, ikke feil.

  it('lar en partially_supports-lenke med annen retning stå uavklart', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          relationshipType: 'partially_supports',
          evidenceItem: { extraction: { reportedDirection: 'decrease' } },
        }),
      ]),
    )

    expect(report.checks.directionAndMagnitude).toBe('not_assessable')
    expect(report.citations[0]?.relationshipSupported).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('lar en partially_supports-lenke med annen komparator stå uavklart', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          relationshipType: 'partially_supports',
          evidenceItem: { extraction: { comparatorKind: 'placebo' } },
        }),
      ]),
    )

    expect(report.checks.comparatorMatch).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('lar en indirekte lenke med annen komparator stå uavklart', () => {
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          directness: 'indirect',
          evidenceItem: { extraction: { comparatorKind: 'placebo' } },
        }),
      ]),
    )

    expect(report.checks.comparatorMatch).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('lar en indirekte lenke med tidspunkt utenfor tidsrommet stå uavklart', () => {
    const report = checkClaim(
      context(
        [
          claimEvidenceLinkFixture({
            directness: 'indirect',
            evidenceItem: {
              extraction: {
                timepointMin: '7 days',
                timepointMax: '7 days',
                timepointAvailability: 'reported_value',
              },
            },
          }),
        ],
        { claim: { timeframeMin: '182 days', timeframeMax: '224 days' } },
      ),
    )

    expect(report.checks.timeframeMatch).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter fortsatt en akse som stemmer, uansett relasjonstype', () => {
    // Innstrammingen gjelder avvik, ikke bekreftelser. Stemmer komparatoren, er
    // den kontrollert også på en indirekte lenke.
    const report = checkClaim(
      context([
        claimEvidenceLinkFixture({
          relationshipType: 'partially_supports',
          directness: 'indirect',
        }),
      ]),
    )

    expect(report.checks.comparatorMatch).toBe('ok')
    expect(report.checks.populationMatch).toBe('ok')
    expect(report.checks.directionAndMagnitude).toBe('ok')
  })

  it('feller fortsatt de sikre motsigelsene på en supports/direct-lenke', () => {
    const direction = checkClaim(
      context([
        claimEvidenceLinkFixture({
          evidenceItem: { extraction: { reportedDirection: 'decrease' } },
        }),
      ]),
    )
    expect(direction.checks.directionAndMagnitude).toBe('deviation')
    expect(direction.citations[0]?.relationshipSupported).toBe('deviation')

    const comparator = checkClaim(
      context([
        claimEvidenceLinkFixture({ evidenceItem: { extraction: { comparatorKind: 'placebo' } } }),
      ]),
    )
    expect(comparator.checks.comparatorMatch).toBe('deviation')

    const population = checkClaim(
      context([
        claimEvidenceLinkFixture({
          evidenceItem: { extraction: { populationLabel: 'healthy volunteers' } },
        }),
      ]),
    )
    expect(population.checks.populationMatch).toBe('deviation')

    expect(direction.outcome).toBe('needs_correction')
    expect(comparator.outcome).toBe('needs_correction')
    expect(population.outcome).toBe('needs_correction')
  })
})

describe('checkClaim — tidsrom', () => {
  it('bekrefter et tidsrom som er nøyaktig det grunnlaget måler', () => {
    const report = checkClaim(
      context(
        [
          claimEvidenceLinkFixture({
            evidenceItem: {
              extraction: {
                timepointMin: '182 days',
                timepointMax: '224 days',
                timepointAvailability: 'reported_value',
              },
            },
          }),
        ],
        { claim: { timeframeMin: '182 days', timeframeMax: '224 days' } },
      ),
    )

    expect(report.checks.timeframeMatch).toBe('ok')
  })

  it('feller et tidspunkt som ligger helt utenfor påstandens tidsrom', () => {
    const report = checkClaim(
      context(
        [
          claimEvidenceLinkFixture({
            evidenceItem: {
              extraction: {
                timepointMin: '7 days',
                timepointMax: '7 days',
                timepointAvailability: 'reported_value',
              },
            },
          }),
        ],
        { claim: { timeframeMin: '182 days', timeframeMax: '224 days' } },
      ),
    )

    expect(report.checks.timeframeMatch).toBe('deviation')
  })

  it('lar delvis overlapp stå uavklart framfor som avvik', () => {
    const report = checkClaim(
      context(
        [
          claimEvidenceLinkFixture({
            evidenceItem: {
              extraction: {
                timepointMin: '56 days',
                timepointMax: '56 days',
                timepointAvailability: 'reported_value',
              },
            },
          }),
        ],
        { claim: { timeframeMin: '56 days', timeframeMax: '224 days' } },
      ),
    )

    expect(report.checks.timeframeMatch).toBe('not_assessable')
    expect(report.outcome).toBe('uncertain')
  })
})

describe('intervalDays', () => {
  it('leser rene dager', () => {
    expect(intervalDays('182 days')).toBe(182)
    expect(intervalDays('1 day')).toBe(1)
  })

  it('leser en klokkedel', () => {
    expect(intervalDays('12:00:00')).toBe(0.5)
    expect(intervalDays('1 day 12:00:00')).toBe(1.5)
  })

  it('nekter å tolke måneder og år', () => {
    // De har ingen fast lengde. En tilnærming ville kunnet gi et *avvik* som
    // ikke er ett, og et avvik er det strengeste utfallet kontrollen kan gi.
    expect(intervalDays('8 mons')).toBeNull()
    expect(intervalDays('1 year 3 days')).toBeNull()
  })

  it('gir null for fravær og for tekst som ikke er et intervall', () => {
    expect(intervalDays(null)).toBeNull()
    expect(intervalDays('')).toBeNull()
    expect(intervalDays('et halvt år')).toBeNull()
  })
})

describe('checkClaim — urepresentert evidens', () => {
  it('fører ulenkede funn på samme virkestoff og endepunkt opp som kandidater', () => {
    const report = checkClaim(
      context([claimEvidenceLinkFixture()], {
        unlinkedRelatedEvidence: [
          {
            evidenceItemId: '59000000-0000-4000-8000-000000000001',
            sourceTitle: 'En studie som ikke er lenket',
            sourceStatus: 'active',
            interventionDrugName: 'sertralin',
            outcomeLabel: 'vektendring',
            reportedDirection: 'decrease',
            effectMeasure: null,
            estimate: null,
            estimateUnit: null,
            createdByActorKey: 'agent:evidence-extraction',
          },
        ],
      }),
    )

    expect(report.findings).toContain('59000000-0000-4000-8000-000000000001')
    expect(report.checks.contradictoryEvidenceRepresented).toBe('not_assessable')
  })

  it('sier eksplisitt at en tom liste ikke betyr at slik evidens ikke finnes', () => {
    const report = checkClaim(context([claimEvidenceLinkFixture()]))

    expect(report.findings).toContain('Antidep kjenner bare den')
  })
})

describe('checkClaim — ukontrollert ekstraksjon under påstanden', () => {
  it('føres opp som funn når den gjeldende ekstraksjonskontrollen ikke bekrefter', () => {
    const report = checkClaim(
      context([claimEvidenceLinkFixture({ currentExtractionVerification: null })]),
    )

    expect(report.findings).toContain('den gjeldende ekstraksjonsverifikasjonen ikke bekrefter')
  })
})
