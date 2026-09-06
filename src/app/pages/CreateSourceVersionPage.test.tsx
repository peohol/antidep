import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { TEST_EDITOR_IDS, TEST_USER_IDS, editorSourceRow, renderRoute } from '../test-support'

const LOOKUPS = { editor_sources: [editorSourceRow()] }

const REPRESENTATION = '<PubmedArticle>Ordrett innhold fra kilden.</PubmedArticle>'

function fillRequiredFields() {
  fireEvent.change(screen.getByLabelText('Adressen representasjonen ble hentet fra'), {
    target: { value: 'https://eksempel.invalid/hentet' },
  })
  fireEvent.change(screen.getByLabelText('Da den ble hentet'), {
    target: { value: '2026-09-07T09:15' },
  })
  fireEvent.change(screen.getByLabelText('Representasjonen, ordrett'), {
    target: { value: REPRESENTATION },
  })
}

describe('Registrer kildeversjon — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, ikke skjemaet', async () => {
    const { rpcCalls } = renderRoute('/source-versions/new', { api: LOOKUPS })
    expect(
      await screen.findByText('Du må logge inn for å registrere en kildeversjon.'),
    ).toBeInTheDocument()
    expect(screen.queryByLabelText('Representasjonen, ordrett')).not.toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Registrer kildeversjon — innlogget', () => {
  it('viser skjemaet uten å spørre om kallerens roller', async () => {
    // Samme doktrine som CreateSourcePage: retten avgjøres av
    // knowledge.assert_editor_authorized(uuid) på serveren, ikke av klienten.
    const { queries } = renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(await screen.findByLabelText('Representasjonen, ordrett')).toBeInTheDocument()
    expect(queries.some((query) => query.view === 'my_roles')).toBe(false)
  })

  it('sender skjemaet som api.create_source_version(...) med tidspunktet som ISO-8601', async () => {
    const { rpcCalls } = renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))

    await screen.findByText(/Kildeversjonen er registrert/)
    expect(rpcCalls).toHaveLength(1)
    expect(rpcCalls[0]?.name).toBe('create_source_version')
    expect(rpcCalls[0]?.args).toMatchObject({
      p_source_id: TEST_EDITOR_IDS.source,
      p_retrieved_from: 'https://eksempel.invalid/hentet',
      p_retrieved_content: REPRESENTATION,
      p_external_version: null,
      p_storage_reference: null,
    })
    const args = rpcCalls[0]?.args as Record<string, unknown>
    expect(String(args['p_retrieved_at'])).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
  })

  // Den viktigste testen i filen. Hashen er databasens, og en klient som sendte
  // en ville gjort verdien til en påstand ingen kan etterprøve (migrasjon 007f).
  it('sender ingen hash: fingeravtrykket eies av databasen', async () => {
    const { rpcCalls } = renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))
    await screen.findByText(/Kildeversjonen er registrert/)

    expect(Object.keys(rpcCalls[0]?.args ?? {})).not.toContain('p_content_hash')
    expect(screen.queryByLabelText(/fingeravtrykk/i)).not.toBeInTheDocument()
  })

  // Hashen skal kunne reproduseres med sha256sum på svaret fra adressen. Et
  // trimmet innhold ville gitt en annen hash enn kilden faktisk gir, og
  // verifikatoren ville rapportert at kilden hadde endret seg.
  it('trimmer ikke innholdet: ett tegn fra eller til er en annen representasjon', async () => {
    const { rpcCalls } = renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.change(screen.getByLabelText('Representasjonen, ordrett'), {
      target: { value: `\n  ${REPRESENTATION}\n` },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))
    await screen.findByText(/Kildeversjonen er registrert/)

    const args = rpcCalls[0]?.args as Record<string, unknown>
    expect(args['p_retrieved_content']).toBe(`\n  ${REPRESENTATION}\n`)
  })

  it('sender valgfrie felter når de er fylt ut', async () => {
    const { rpcCalls } = renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.change(screen.getByLabelText('Kildens eget versjonsmerke (valgfritt)'), {
      target: { value: 'MEDLINE DateRevised 2026-01-28' },
    })
    fireEvent.change(screen.getByLabelText('Peker til lagret kopi (valgfritt)'), {
      target: { value: 'lagring://bøtte/fil.xml' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))
    await screen.findByText(/Kildeversjonen er registrert/)

    expect(rpcCalls[0]?.args).toMatchObject({
      p_external_version: 'MEDLINE DateRevised 2026-01-28',
      p_storage_reference: 'lagring://bøtte/fil.xml',
    })
  })

  it('viser databasens egen avvisning, og lar skjemaet stå utfylt', async () => {
    renderRoute('/source-versions/new', {
      api: {
        ...LOOKUPS,
        create_source_version: {
          error:
            'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
        },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Nøyaktig samme innhold er allerede registrert',
    )
    expect(screen.getByLabelText('Representasjonen, ordrett')).toHaveValue(REPRESENTATION)
  })

  it('bekreftelsen peker videre til evidensregistreringen', async () => {
    renderRoute('/source-versions/new', {
      api: LOOKUPS,
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    fillRequiredFields()
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kildeversjon' }))

    await screen.findByText(/Kildeversjonen er registrert/)
    expect(screen.getByRole('link', { name: 'registrere et evidensfunn' })).toHaveAttribute(
      'href',
      '/evidence/new',
    )
  })

  it('sier hva et tomt kilderegister betyr, framfor å vise et skjema uten kilder', async () => {
    renderRoute('/source-versions/new', {
      api: { editor_sources: [] },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(
      await screen.findByText('Du har ingen kilder å registrere en kildeversjon for.'),
    ).toBeInTheDocument()
    expect(screen.queryByLabelText('Representasjonen, ordrett')).not.toBeInTheDocument()
  })

  it('en tilbaketrukket kilde vises med statusen sin i nedtrekkslisten', async () => {
    // ANTIDEP_CONSTITUTION.md §14: en tilbaketrukket kilde skal ikke stille
    // kunne velges som om den var normal. Regelen ligger i `sourceChoice`, delt
    // med evidensskjemaet, nettopp for at de to ikke skal kunne svare ulikt.
    renderRoute('/source-versions/new', {
      api: { editor_sources: [editorSourceRow({ source_status: 'retracted' })] },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByLabelText('Representasjonen, ordrett')
    expect(screen.getByRole('option').textContent).toMatch(/trukket tilbake/i)
  })
})
