import { describe, expect, it } from 'vitest'

import {
  parsePublicationOutcome,
  parsePublishedClaim,
  parsePublishedClaimIndex,
  rollbackTargets,
} from './published-claim'
import {
  candidateContent,
  publicationHistoryEvent,
  publicationOutcomeResponse,
  publishedClaimResponse,
  publishedIndexEntry,
  FIXTURE_CANDIDATE_DIGEST,
  FIXTURE_CANDIDATE_ID,
  FIXTURE_CLAIM_ID,
  FIXTURE_STATEMENT,
} from './candidate-test-support'

describe('det publiserte innholdet', () => {
  it('leser innholdet med den samme lesingen kandidatvisningen bruker', () => {
    const view = parsePublishedClaim(publishedClaimResponse())

    expect(view.published).toBe(true)
    expect(view.claimId).toBe(FIXTURE_CLAIM_ID)
    expect(view.candidateId).toBe(FIXTURE_CANDIDATE_ID)
    expect(view.candidateDigest).toBe(FIXTURE_CANDIDATE_DIGEST)
    expect(view.content?.claim.statement).toBe(FIXTURE_STATEMENT)
    // Innholdet bæres uendret: avtrykket dekker nøyaktig dette, og en lesing
    // som plukket ut felter ville vist noe annet enn det som ble godkjent.
    expect(view.content?.sealedContent).toEqual(candidateContent())
  })

  it('bærer proveniensen tilbake til sluttkontrollen og publiseringshendelsen', () => {
    const view = parsePublishedClaim(publishedClaimResponse())

    expect(view.finalControl?.decision).toBe('approved')
    expect(view.finalControl?.reviewer).toBe('Navngitt fagperson')
    expect(view.publication?.action).toBe('publish')
    expect(view.publication?.publishedBy).toBe('Navngitt publisher')
    expect(view.history).toHaveLength(1)
  })

  // ANTIDEP_CONSTITUTION.md regel 4: et innhold som ikke vises, skal ikke kunne
  // forveksles med et innhold uten forbehold.
  it('skiller «trukket tilbake» fra «ingenting å vise»', () => {
    const withdrawn = parsePublishedClaim({
      claim_id: FIXTURE_CLAIM_ID,
      published: false,
      withdrawn: true,
      content: null,
      history: [publicationHistoryEvent({ action: 'withdraw', final_control: null })],
    })

    expect(withdrawn.published).toBe(false)
    expect(withdrawn.withdrawn).toBe(true)
    expect(withdrawn.content).toBeNull()
    expect(withdrawn.candidateDigest).toBeNull()
    // Historikken er hele poenget med at tilbaketrekkingen er synlig.
    expect(withdrawn.history[0]?.action).toBe('withdraw')
    expect(withdrawn.history[0]?.finalControl).toBeNull()
  })

  it('avviser et svar uten innhold når det sier at noe er publisert', () => {
    expect(() => parsePublishedClaim(publishedClaimResponse({ content: null }))).toThrowError(
      /content er ikke et objekt/,
    )
  })

  it('avviser et svar uten historikk framfor å vise en tom liste', () => {
    const rest = publishedClaimResponse()
    delete rest['history']
    expect(() => parsePublishedClaim(rest)).toThrowError(/svaret.history er ikke en liste/)
  })
})

describe('den publiserte katalogen', () => {
  it('leser radene, med sikkerhetsgraden som en egen tilstand', () => {
    const rows = parsePublishedClaimIndex([
      publishedIndexEntry(),
      publishedIndexEntry({
        claim_id: '77777777-7777-4777-8777-777777777777',
        certainty_level: null,
      }),
    ])

    expect(rows).toHaveLength(2)
    expect(rows[0]?.certaintyLevel).toBe('low')
    // NULL betyr «ingen vurdering er registrert», ikke «lav sikkerhet».
    expect(rows[1]?.certaintyLevel).toBeNull()
  })

  it('avviser noe annet enn en liste', () => {
    expect(() => parsePublishedClaimIndex({})).toThrowError(/katalogen er ikke en liste/)
  })
})

describe('utfallet av en publiseringshandling', () => {
  it('sier om noe faktisk ble endret', () => {
    expect(parsePublicationOutcome(publicationOutcomeResponse()).changed).toBe(true)
    expect(parsePublicationOutcome(publicationOutcomeResponse({ changed: false })).changed).toBe(
      false,
    )
  })

  it('bærer hendelsen, med både innholdet etter og innholdet før', () => {
    const outcome = parsePublicationOutcome(
      publicationOutcomeResponse({
        action: 'rollback',
        previous_candidate_id: '88888888-8888-4888-8888-888888888888',
        previous_candidate_digest: `sha256:${'c'.repeat(64)}`,
      }),
    )

    expect(outcome.event.action).toBe('rollback')
    expect(outcome.event.candidateId).toBe(FIXTURE_CANDIDATE_ID)
    expect(outcome.event.previousCandidateId).toBe('88888888-8888-4888-8888-888888888888')
  })
})

describe('målene en rollback kan gå tilbake til', () => {
  const eldre = publicationHistoryEvent({
    publication_event_id: '99999999-9999-4999-8999-999999999999',
    candidate_id: '88888888-8888-4888-8888-888888888888',
    candidate_digest: `sha256:${'c'.repeat(64)}`,
  })

  it('utelater den gjeldende versjonen: en rollback til den er ingen endring', () => {
    const view = parsePublishedClaim(
      publishedClaimResponse({ history: [publicationHistoryEvent(), eldre] }),
    )
    const targets = rollbackTargets(view)

    expect(targets).toHaveLength(1)
    expect(targets[0]?.candidateId).toBe('88888888-8888-4888-8888-888888888888')
  })

  it('utelater tilbaketrekkinger: de etterlater ikke noe innhold å gå tilbake til', () => {
    const view = parsePublishedClaim(
      publishedClaimResponse({
        history: [
          publicationHistoryEvent({
            publication_event_id: '10000000-0000-4000-8000-000000000000',
            action: 'withdraw',
            candidate_id: null,
            candidate_digest: null,
            final_control: null,
          }),
          publicationHistoryEvent(),
          eldre,
        ],
      }),
    )

    expect(rollbackTargets(view).map((target) => target.candidateId)).toEqual([
      '88888888-8888-4888-8888-888888888888',
    ])
  })

  it('nevner den samme versjonen én gang, uansett hvor mange ganger den var publisert', () => {
    const view = parsePublishedClaim(
      publishedClaimResponse({
        history: [
          publicationHistoryEvent(),
          eldre,
          publicationHistoryEvent({
            publication_event_id: '20000000-0000-4000-8000-000000000000',
            candidate_id: '88888888-8888-4888-8888-888888888888',
            candidate_digest: `sha256:${'c'.repeat(64)}`,
          }),
        ],
      }),
    )

    expect(rollbackTargets(view)).toHaveLength(1)
  })
})
