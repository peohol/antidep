import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_EXTRACTION_IDS,
  TEST_USER_IDS,
  extractionQueueItem,
  extractionQueuePayload,
  renderRoute,
} from '../test-support'

const PATH = '/extraction-review'

function renderQueue(payload: unknown = extractionQueuePayload()) {
  return renderRoute(PATH, {
    api: { extraction_review_queue: { data: payload } },
    auth: { initialUserId: TEST_USER_IDS.a },
  })
}

describe('Køen for kildekontroll — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute(PATH)
    expect(
      await screen.findByText('Du må logge inn for å se køen for kildekontroll.'),
    ).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Køen for kildekontroll', () => {
  it('henter køen uten å be om et bestemt funn', async () => {
    const { rpcCalls } = renderQueue()
    await screen.findByRole('link', { name: 'Testkilde A: vektendring ved åtte uker' })
    expect(rpcCalls).toEqual([
      { name: 'extraction_review_workspace', args: { p_evidence_item_id: null } },
    ])
  })

  it('lenker hver rad til kontrollflaten for nøyaktig det funnet', async () => {
    renderQueue()
    const link = await screen.findByRole('link', {
      name: 'Testkilde A: vektendring ved åtte uker',
    })
    expect(link).toHaveAttribute('href', `/extraction-review/${TEST_EXTRACTION_IDS.evidenceItem}`)
  })

  // Fravær står som fravær. «Ingen registrert» er ikke det samme som en kontroll
  // som konkluderte negativt (ANTIDEP_CONSTITUTION.md §17).
  it('viser en manglende kontroll som fravær, ikke som et negativt utfall', async () => {
    renderQueue()
    expect(await screen.findByText('ingen registrert')).toBeInTheDocument()
  })

  it('viser utfallet av den gjeldende kontrollen når det finnes', async () => {
    renderQueue(
      extractionQueuePayload([
        extractionQueueItem({ current_extraction_verification_outcome: 'uncertain' }),
      ]),
    )
    expect(await screen.findByText(/Uavklart/)).toBeInTheDocument()
  })

  // Tallene kommer fra publiseringsgatens egne funksjoner. Raden regner ingenting
  // ut på nytt; den trekker den ene listen fra den andre.
  it('sier hvor mange felter som står igjen av dem som kreves', async () => {
    renderQueue(
      extractionQueuePayload([
        extractionQueueItem({
          required_check_fields: ['source_locator', 'outcome', 'estimate'],
          covered_check_fields: ['outcome'],
        }),
      ]),
    )
    expect(await screen.findByText(/Felter som står igjen: 2 av 3/)).toBeInTheDocument()
  })

  it('sier at ingenting står igjen når dekningen er komplett', async () => {
    renderQueue(
      extractionQueuePayload([
        extractionQueueItem({
          required_check_fields: ['source_locator'],
          covered_check_fields: ['source_locator'],
        }),
      ]),
    )
    expect(await screen.findByText(/Felter som står igjen: ingen av 1/)).toBeInTheDocument()
  })

  // En tom kø er ikke et svar om at alle ekstraksjoner er kontrollert.
  it('skiller en tom kø fra en manglende tilgang', async () => {
    renderQueue(extractionQueuePayload([]))
    expect(
      await screen.findByText('Ingen evidensfunn venter på kildekontroll fra deg nå.'),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/At den er tom, betyr ikke at alle ekstraksjoner er kontrollert/),
    ).toBeInTheDocument()
  })

  it('viser databasens egen avvisning når kalleren mangler rollen', async () => {
    renderRoute(PATH, {
      api: {
        extraction_review_queue: { error: 'Brukeren har ikke gyldig reviewer-rolle.' },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(await screen.findByText('Antidep fikk ikke hentet køen.')).toBeInTheDocument()
    expect(screen.getByText(/Brukeren har ikke gyldig reviewer-rolle\./)).toBeInTheDocument()
  })
})
