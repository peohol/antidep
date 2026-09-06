import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_CLAIM_IDS,
  TEST_SOURCE_IDS,
  claimRow,
  drugRow,
  evidenceRow,
  renderRoute,
} from './test-support'

describe('skallet', () => {
  it('viser produktnavnet i en toppbanner, som vei tilbake til forsiden', () => {
    renderRoute('/')
    const banner = screen.getByRole('banner')
    const heading = within(banner).getByRole('heading', { level: 1, name: 'Antidep' })
    expect(heading).toBeInTheDocument()
    expect(within(heading).getByRole('link')).toHaveAttribute('href', '/')
  })

  it('sier at innholdet ikke skal brukes til kliniske beslutninger ennå', () => {
    // Flaten viser nå klinisk innhold. Da må den også si hva den ikke er.
    renderRoute('/')
    expect(screen.getByRole('banner')).toHaveTextContent(
      /skal ikke brukes som grunnlag for kliniske beslutninger ennå/i,
    )
  })

  it('har en hopplenke til hovedinnholdet som første fokuserbare element', () => {
    // §49 og §52: en tastaturbruker skal slippe å gå gjennom toppen på nytt for
    // hver navigering.
    renderRoute('/')
    const skip = screen.getByRole('link', { name: 'Hopp til hovedinnhold' })
    expect(skip).toHaveAttribute('href', `#${screen.getByRole('main').id}`)
    expect(document.body.querySelector('a')).toBe(skip)
  })

  it('har en lenke til Min tilgang i toppen, uavhengig av innloggingsstatus', () => {
    // Steg 1 av adminflyten (§29, §74.22): lenken skal stå i toppen for alle,
    // ikke bare gjemt bak en klinikerflate som forutsetter innlogging.
    renderRoute('/')
    const banner = screen.getByRole('banner')
    expect(within(banner).getByRole('link', { name: 'Min tilgang' })).toHaveAttribute(
      'href',
      '/access',
    )
  })

  it('har en lenke til Opprett kilde i toppen, uavhengig av innloggingsstatus', () => {
    // Steg 2 av adminflyten (§29, §74.24): ingen rollegate i lenken heller,
    // se CreateSourcePage.tsx sin doc-kommentar.
    renderRoute('/')
    const banner = screen.getByRole('banner')
    expect(within(banner).getByRole('link', { name: 'Opprett kilde' })).toHaveAttribute(
      'href',
      '/sources/new',
    )
  })

  it('har adminlenkene i toppen, i kjedens egen rekkefølge', () => {
    // Rekkefølgen er kjedens (§15): en kilde må finnes før en versjon av den kan
    // registreres, og en versjon før et evidensfunn kan peke på den.
    renderRoute('/')
    const admin = screen.getByRole('navigation', { name: 'Admin' })
    expect(within(admin).getByRole('link', { name: 'Registrer kildeversjon' })).toHaveAttribute(
      'href',
      '/source-versions/new',
    )
    expect(within(admin).getByRole('link', { name: 'Registrer evidensfunn' })).toHaveAttribute(
      'href',
      '/evidence/new',
    )
    const links = within(admin)
      .getAllByRole('link')
      .map((link) => link.textContent)
    expect(links).toEqual(['Opprett kilde', 'Registrer kildeversjon', 'Registrer evidensfunn'])
  })
})

describe('rutingen', () => {
  it('forsiden viser den publiserte indeksen', () => {
    renderRoute('/')
    expect(
      screen.getByRole('heading', { level: 2, name: 'Publisert kunnskap' }),
    ).toBeInTheDocument()
  })

  it('en ukjent adresse sier at adressen er ukjent, ikke noe om klinikk', () => {
    renderRoute('/finnes-ikke')
    expect(screen.getByRole('heading', { level: 2, name: 'Ukjent adresse' })).toBeInTheDocument()
    expect(screen.getByRole('main')).toHaveTextContent('/finnes-ikke')
  })

  it('legemiddeladressen fra §30 treffer legemiddelsiden', async () => {
    renderRoute('/drugs/sertralin', {
      api: { published_drugs: [drugRow({ canonical_name: 'sertralin' })] },
    })
    expect(await screen.findByRole('heading', { level: 2, name: 'sertralin' })).toBeInTheDocument()
  })

  it('temaadressen treffer temasiden', async () => {
    renderRoute('/topics/vektendring', { api: { published_claims: [claimRow()] } })
    expect(
      await screen.findByRole('heading', { level: 2, name: 'vektendring' }),
    ).toBeInTheDocument()
  })

  it('evidensadressen treffer evidensvisningen', async () => {
    // Adressen bygges av `claimEvidencePath()` og er den eneste veien til
    // «Hvorfor sier Antidep dette?» fra hvert kort.
    renderRoute(`/claims/${TEST_CLAIM_IDS.a}/evidence`, {
      api: { published_claims: [claimRow()], published_claim_evidence: [evidenceRow()] },
    })
    expect(
      await screen.findByRole('heading', { level: 3, name: 'Evidensgrunnlaget' }),
    ).toBeInTheDocument()
  })

  it('adressen /access treffer Min tilgang', () => {
    renderRoute('/access')
    expect(screen.getByRole('heading', { level: 2, name: 'Min tilgang' })).toBeInTheDocument()
  })

  it('kildeadressen treffer kildesiden', async () => {
    // Den andre halvdelen av §42: fra ett funn til alt Antidep bruker kilden til.
    renderRoute(`/sources/${TEST_SOURCE_IDS.a}`, {
      api: { published_claims: [claimRow()], published_claim_evidence: [evidenceRow()] },
    })
    expect(
      await screen.findByRole('heading', { level: 3, name: 'Publikasjonen' }),
    ).toBeInTheDocument()
  })

  it('/sources/new treffer Opprett kilde, ikke kildesidens :sourceId (§74.24)', () => {
    // Det statiske segmentet skal rangeres foran det dynamiske av react-router
    // selv — se doc-kommentaren på newSourcePath(). Prøvd direkte, ikke bare
    // antatt: en regresjon her ville sendt «new» inn i SourcePage som om det
    // var en uuid.
    renderRoute('/sources/new')
    expect(screen.getByRole('heading', { level: 2, name: 'Opprett kilde' })).toBeInTheDocument()
  })

  it('/evidence/new treffer Registrer evidensfunn', () => {
    renderRoute('/evidence/new')
    expect(
      screen.getByRole('heading', { level: 2, name: 'Registrer evidensfunn' }),
    ).toBeInTheDocument()
  })

  it('setter dokumenttittelen per adresse', async () => {
    renderRoute('/drugs/sertralin', {
      api: { published_drugs: [drugRow({ canonical_name: 'sertralin' })] },
    })
    await waitFor(() => {
      expect(document.title).toBe('sertralin – Antidep')
    })
  })
})

describe('navigering', () => {
  it('flytter fokus til hovedinnholdet, men ikke ved første render', async () => {
    // Uten dette blir en skjermleser stående igjen i forrige side.
    renderRoute('/', {
      api: { published_drugs: [drugRow({ canonical_name: 'sertralin' })] },
    })
    const main = screen.getByRole('main')
    expect(main).not.toHaveFocus()

    fireEvent.click(await screen.findByRole('link', { name: 'sertralin' }))

    await waitFor(() => {
      expect(main).toHaveFocus()
    })
  })

  it('lenken fra forsiden går til adressen legemiddelsiden svarer på', async () => {
    renderRoute('/', { api: { published_drugs: [drugRow({ canonical_name: 'sertralin' })] } })
    expect(await screen.findByRole('link', { name: 'sertralin' })).toHaveAttribute(
      'href',
      '/drugs/sertralin',
    )
  })
})
