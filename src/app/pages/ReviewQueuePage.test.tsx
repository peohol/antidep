import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_REVIEW_IDS,
  TEST_USER_IDS,
  renderRoute,
  reviewQueueItem,
  reviewQueuePayload,
} from '../test-support'

describe('Reviewkøen — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute('/review')
    expect(await screen.findByText('Du må logge inn for å se reviewkøen.')).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Reviewkøen — innlogget', () => {
  it('henter køen uten å spørre om kallerens roller', async () => {
    // Samme doktrine som registreringssidene: retten avgjøres av
    // workflow.assert_reviewer_authorized(uuid) på serveren, ikke av klienten.
    // En rollegate her ville lovet noe klienten ikke kan stå for.
    const { queries, rpcCalls } = renderRoute('/review', {
      api: { claim_review_queue: { data: reviewQueuePayload() } },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByRole('link', {
      name: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
    })
    expect(queries.some((query) => query.view === 'my_roles')).toBe(false)
    expect(rpcCalls).toEqual([
      { name: 'claim_review_workspace', args: { p_claim_revision_id: null } },
    ])
  })

  it('lenker hver kørad til arbeidsflaten for nøyaktig den revisjonen', async () => {
    renderRoute('/review', {
      api: { claim_review_queue: { data: reviewQueuePayload() } },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    const link = await screen.findByRole('link', {
      name: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
    })
    expect(link).toHaveAttribute('href', `/review/${TEST_REVIEW_IDS.revision}`)
  })

  it('skiller «ingen registrert kontroll» fra en kontroll med et negativt utfall', async () => {
    // ANTIDEP_CONSTITUTION.md §17: fravær skal ikke kunne leses som et svar.
    renderRoute('/review', {
      api: { claim_review_queue: { data: reviewQueuePayload() } },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    const status = await screen.findByText(/Kontroll mot grunnlaget:/)
    expect(status).toHaveTextContent('Kontroll mot grunnlaget: ingen registrert')
    expect(status).toHaveTextContent('Publiseringsbeslutning: ingen registrert')
  })

  it('viser utfallet av den gjeldende kontrollen når den finnes', async () => {
    renderRoute('/review', {
      api: {
        claim_review_queue: {
          data: reviewQueuePayload([
            reviewQueueItem({
              current_claim_verification_outcome: 'uncertain',
              current_publication_decision: 'changes_requested',
            }),
          ]),
        },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    const status = await screen.findByText(/Kontroll mot grunnlaget:/)
    expect(status).toHaveTextContent('Uavklart')
    expect(status).toHaveTextContent('Endringer bedt om')
  })

  it('sier hva en tom kø betyr, og hva den ikke betyr', async () => {
    renderRoute('/review', {
      api: { claim_review_queue: { data: reviewQueuePayload([]) } },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(
      await screen.findByText('Ingen påstandsrevisjoner venter på vurdering nå.'),
    ).toBeInTheDocument()
    expect(screen.getByText(/betyr ikke at kunnskapsbasen er ferdig vurdert/)).toBeInTheDocument()
  })

  it('viser databasens avvisning som en feil, aldri som en tom kø', async () => {
    // En kaller uten reviewer-rolle avvises av api-funksjonen. Å vise det som
    // «ingenting venter» ville vært å skjule en rettighetsfeil bak en tom liste.
    renderRoute('/review', {
      api: { claim_review_queue: { error: 'Brukeren har ikke gyldig reviewer-rolle.' } },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Brukeren har ikke gyldig reviewer-rolle.',
    )
    expect(screen.queryByText('Ingen påstandsrevisjoner venter på vurdering nå.')).toBeNull()
  })
})
