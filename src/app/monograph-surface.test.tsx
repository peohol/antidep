// ============================================================================
// Monografiflaten, prøvd som spørsmål et menneske ville stilt
//
//   * kan en kliniker bestille «Bygg monografi for sertralin» uten å foreslå
//     én eneste artikkel?
//   * står dekningen som flere atskilte tall, framfor ett som skjuler de andre?
//   * ser et delvis utkast ut som et delvis utkast?
//   * kan «venter på tilgang» leses som «ingen relevante studier»?
//   * bæres hver tilstand av et tegn og en tekst, og ikke av en farge alene?
//   * ligger dybden bak en knapp, slik at hovedbildet har få punkter?
//   * kan en redaktør rette teksten, låse den, og avgjøre et avvik — uten kode,
//     SQL eller en utviklingsagent?
//   * vises et låst svar som får ny evidens som et *synlig* avvik, framfor å bli
//     skjermet mot kritikk eller overskrevet i stillhet?
//   * lekker flaten en uuid, en jobbnøkkel, et privat originaldokument eller et
//     internt utdrag?
//   * tåler den samme siden en telefonbredde og en skjermbredde?
// ============================================================================

import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'

import { AppLayout } from './App'
import { GatewayFailure } from './gateway'
import type { MonographGateway } from './monograph-gateway'
import {
  parseMonographDraft,
  parseMonographOrders,
  parseMonographProposals,
  parseMonographRequests,
} from '../lib/monograph'

const REFERENCE = '3c7a1f5e9b2d4a6c8e0f1a3b'

/** En intern id som aldri skal nå fram til flaten. */
const INTERNAL_ID = '11111111-1111-4111-8111-111111111111'

const COVERAGE = {
  edition: {
    reference: REFERENCE,
    drug: 'sertralin',
    standard_version: '2026.1',
    edition_no: 1,
    ordered_at: '2026-09-01T10:00:00+00:00',
  },
  needs: {
    total: 92,
    relevant: 70,
    justified_not_applicable: 12,
    undetermined_relevance: 10,
    answered: 31,
    reviewed_gaps: 7,
    open: 32,
  },
  blocked: { awaiting_access: 4, awaiting_clarification: 1, technical_stop: 2 },
  work_coverage: { handled: 50, denominator: 92, percent: 54 },
  completion: { level: 'coverage_map', partial: true },
}

const DRAFT = {
  edition: { reference: REFERENCE, drug: 'sertralin', standard_version: '2026.1' },
  sections: [
    {
      section: 'Effekt',
      entries: [
        {
          need_reference: 'n1',
          template_code: 'MN29',
          question: 'Hvor godt virker midlet ved depresjon hos voksne?',
          requirement: 'mandatory',
          scope: 'voksne · depresjon',
          relevance: 'relevant',
          relevance_reason: null,
          work_state: 'agent_complete',
          work_state_note: null,
          outcome: 'answered',
          answer: {
            revision_reference: 'r1',
            revision_number: 2,
            knowledge_type: 'research_finding',
            origin: 'agent',
            statement: 'Effekten er liten til moderat sammenliknet med placebo.',
            uncertainty_summary: 'Konfidensintervallet er bredt.',
            limitation_note: 'Ett søk nådde ikke fram, og er åpent.',
            as_of: null,
            recommending_body: null,
            certainty: 'low',
            sources: [],
            evidence_sources: [
              {
                title: 'Sertraline versus placebo in adults',
                authors_or_issuer: 'Testforfatter A mfl.',
                publisher_or_journal: 'Et tidsskrift',
                locator: '10.1000/xyz',
                as_of: null,
                retrieved_from: null,
              },
            ],
            controlled_fields: ['statement', 'certainty'],
          },
        },
        {
          need_reference: 'n2',
          template_code: 'MN30',
          question: 'Hvor godt virker midlet hos barn og unge?',
          requirement: 'conditional',
          scope: null,
          relevance: 'undetermined',
          relevance_reason: null,
          work_state: 'awaiting_access',
          work_state_note: 'Artikkelen ligger bak en betalingsmur hos utgiveren.',
          outcome: null,
          answer: null,
        },
      ],
    },
  ],
  coverage: COVERAGE,
  latest_candidate: null,
  published: null,
}

const REQUESTS = {
  research_full_text: [
    {
      reference: 'q1',
      kind: 'research_full_text',
      title: 'Sertraline in adolescents',
      authors_or_issuer: 'Testforfatter B mfl.',
      publisher_or_journal: 'Et annet tidsskrift',
      professional_reason: 'Trengs for spørsmålet om effekt hos barn og unge.',
      access_limitation: 'Betalingsmur hos utgiveren',
    },
  ],
  authority_documents: [],
}

const PROPOSALS = {
  proposals: [
    {
      reference: 'p1',
      kind: 'locked_answer_challenged',
      template_code: 'MN29',
      question: 'Hvor godt virker midlet ved depresjon hos voksne?',
      scope: 'voksne · depresjon',
      rationale: 'En nyere kontrollert studie peker i en annen retning enn det låste svaret.',
      source_title: 'Sertraline reconsidered',
    },
  ],
}

function monograph(overrides: Partial<MonographGateway> = {}): MonographGateway {
  return {
    listOrders: () => Promise.resolve(parseMonographOrders([COVERAGE])),
    order: () => Promise.resolve(null),
    options: () => Promise.resolve({ drugs: ['sertralin', 'escitalopram'], questionTemplates: 80 }),
    draft: () => Promise.resolve(parseMonographDraft(DRAFT)),
    requests: () => Promise.resolve(parseMonographRequests(REQUESTS)),
    proposals: () => Promise.resolve(parseMonographProposals(PROPOSALS)),
    decideProposal: () => Promise.resolve(),
    editAnswer: () => Promise.resolve(),
    lockAnswer: () => Promise.resolve(),
    unlockAnswer: () => Promise.resolve(),
    buildCandidate: () => Promise.resolve({ reference: 'k1', digest: 'sha256:abc' }),
    ...overrides,
  }
}

function renderAt(path: string, gateway: MonographGateway = monograph()) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppLayout monograph={gateway} />
    </MemoryRouter>,
  )
}

// ----------------------------------------------------------------------------
// Bestillingen
// ----------------------------------------------------------------------------

describe('bestillingen', () => {
  it('lar klinikeren velge et virkestoff og bestille hele monografien', async () => {
    const order = vi.fn(() => Promise.resolve(null))
    renderAt('/monografi', monograph({ order }))

    expect(
      await screen.findByRole('heading', { level: 1, name: 'Bygg en monografi' }),
    ).toBeVisible()
    const select = await screen.findByLabelText('Virkestoff')
    fireEvent.change(select, { target: { value: 'sertralin' } })
    fireEvent.click(await screen.findByRole('button', { name: 'Bygg monografi for sertralin' }))

    await waitFor(() => {
      expect(order).toHaveBeenCalledWith('sertralin', '')
    })
    expect(
      await screen.findByText(/oppretter kunnskapsbehovene og begynner å lete etter kilder selv/),
    ).toBeVisible()
  })

  // Dette er hele produktmålet: klinikeren skal ikke sitte med en artikkelliste.
  // En flate som ba om en DOI eller en tittel for å komme i gang, ville vært den
  // gamle, manuelle inngangen med et nytt navn.
  it('ber ikke klinikeren om en artikkel, en DOI eller en kildeliste', async () => {
    renderAt('/monografi')
    await screen.findByRole('heading', { level: 1, name: 'Bygg en monografi' })

    expect(screen.getByText(/Du skal ikke foreslå artikler én for én/)).toBeVisible()
    expect(screen.queryByLabelText(/DOI/i)).toBeNull()
    expect(screen.queryByLabelText(/Artikkel/i)).toBeNull()
    expect(screen.queryByLabelText(/Tittel/i)).toBeNull()
  })

  // 80 maler er ikke 80 kunnskapsbehov. Flaten sier det, framfor å la et tall
  // se ut som et løfte om hvor mange søk eller artikler det blir.
  it('sier at antallet maler ikke er antallet kunnskapsbehov', async () => {
    renderAt('/monografi')
    expect(await screen.findByText(/Standarden stiller 80 spørsmål/)).toBeVisible()
    expect(screen.getByText(/faktiske antallet kunnskapsbehov blir større/)).toBeVisible()
  })

  it('viser tellingene hver for seg i listen over bestillinger', async () => {
    renderAt('/monografi')
    const item = within(
      (await screen.findByRole('link', { name: /Monografi for sertralin/ })).closest(
        'li',
      ) as HTMLElement,
    )
    expect(item.getByText(/31 av 92 spørsmål er besvart/)).toBeVisible()
    expect(item.getByText(/10 har uavklart relevans/)).toBeVisible()
    expect(item.getByText(/32 står fortsatt åpne/)).toBeVisible()
  })

  it('sier hva som mangler når den innloggede ikke har redaktørmandat', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    renderAt(
      '/monografi',
      monograph({
        listOrders: () =>
          Promise.reject(
            new GatewayFailure(
              'Å bestille og lese en monografi under arbeid er redaksjonelt arbeid, og krever ' +
                'redaktørmandat. Ta kontakt med en administrator hvis du skulle hatt det.',
              'not_authorized',
              'clinical_content',
            ),
          ),
      }),
    )
    expect(await screen.findByText(/krever redaktørmandat/)).toBeVisible()
    spy.mockRestore()
  })
})

// ----------------------------------------------------------------------------
// Utgaven: dekningen, og hva den ikke sier
// ----------------------------------------------------------------------------

describe('dekningen i utgaven', () => {
  it('viser de seks tellingene som seks tall, og ikke som ett', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    const dekning = within(await screen.findByRole('region', { name: 'Dekning' }))

    for (const [tall, hva] of [
      ['31', 'besvarte spørsmål'],
      ['7', 'gjennomgåtte kunnskapshull eller motstrider'],
      ['12', 'begrunnet ikke relevante'],
      ['10', 'med uavklart relevans'],
      ['32', 'fortsatt åpne'],
      ['92', 'spørsmål i alt'],
    ]) {
      const label = dekning.getByText(hva as string)
      expect(label).toBeVisible()
      expect(within(label.closest('li') as HTMLElement).getByText(tall as string)).toBeVisible()
    }
  })

  // Det viktigste enkeltkravet: en betalingsmur, en avklaring og en teknisk feil
  // er ikke faglige konklusjoner, og flaten sier det med ord.
  it('sier at det som står i veien, ikke er en konklusjon om kunnskapen', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    const dekning = within(await screen.findByRole('region', { name: 'Dekning' }))

    expect(dekning.getByText(/4 spørsmål venter på at Antidep får tilgang/)).toBeVisible()
    expect(dekning.getByText(/1 spørsmål venter på en avklaring fra et menneske/)).toBeVisible()
    expect(dekning.getByText(/2 spørsmål står på en teknisk feil/)).toBeVisible()
    expect(dekning.getByText(/Ingen av disse er en konklusjon om kunnskapen/)).toBeVisible()
    expect(dekning.queryByText(/utilstrekkelig evidens/i)).toBeNull()
    expect(dekning.queryByText(/ingen relevante studier/i)).toBeNull()
  })

  it('merker et delvis utkast som delvis, med tallene bak', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    expect(await screen.findByText(/Dette er et delvis utkast/)).toBeVisible()
    expect(screen.getByText(/32 av 92 spørsmål er ikke ferdig behandlet/)).toBeVisible()
    expect(screen.getByText('Dekningskart under arbeid')).toBeVisible()
  })

  // Et agentferdig dekningskart er ikke et publisert innhold, og ingen del av
  // flaten skal antyde at et menneske har vurdert noe.
  it('kaller et agentferdig kart behandlet, ikke godkjent eller publisert', async () => {
    renderAt(
      `/monografi/${REFERENCE}`,
      monograph({
        draft: () =>
          Promise.resolve(
            parseMonographDraft({
              ...DRAFT,
              coverage: { ...COVERAGE, completion: { level: 'agent_complete', partial: false } },
            }),
          ),
      }),
    )
    expect(await screen.findByText('Alle spørsmål er behandlet av Antidep')).toBeVisible()
    expect(screen.queryByText(/Dette er et delvis utkast/)).toBeNull()
    // Bare selve siden: navigasjonen har en lenke til det publiserte innholdet
    // på hver eneste flate, og den er ikke en påstand om denne utgaven.
    const side = within(screen.getByRole('main'))
    expect(side.queryByText(/godkjent/i)).toBeNull()
    expect(side.queryByText(/publisert/i)).toBeNull()
  })
})

// ----------------------------------------------------------------------------
// Spørsmålene, tilstandene og dybden
// ----------------------------------------------------------------------------

describe('spørsmålene i utkastet', () => {
  async function openSection() {
    renderAt(`/monografi/${REFERENCE}`)
    fireEvent.click(await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ }))
  }

  // Progressiv dybde: hovedbildet har få punkter, og seksjonene er lukket til
  // noen ber om dem.
  it('holder spørsmålene lukket til seksjonen åpnes', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    const toggle = await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('Hvor godt virker midlet ved depresjon hos voksne?')).toBeNull()

    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(
      await screen.findByText('Hvor godt virker midlet ved depresjon hos voksne?'),
    ).toBeVisible()
  })

  // WCAG 1.4.1: tilstanden bæres av tegn og tekst. En prøve som bare så etter
  // en css-klasse, ville godtatt en flate der fargen var hele beskjeden.
  it('bærer hver tilstand med både tegn og tekst', async () => {
    await openSection()
    const entry = (
      await screen.findByText('Hvor godt virker midlet ved depresjon hos voksne?')
    ).closest('li') as HTMLElement

    for (const label of ['Relevant', 'Ferdig behandlet', 'Besvart']) {
      const badge = within(entry).getByText(label)
      expect(badge).toBeVisible()
      // Tegnet står i sitt eget element ved siden av teksten, skjult for en
      // skjermleser som allerede leser teksten.
      expect(badge.querySelector('.status__mark')?.textContent?.length ?? 0).toBeGreaterThan(0)
    }
  })

  // Det blokkerte spørsmålet er stedet regelen brytes eller holder: det har
  // ingen faglig konklusjon, og teksten sier hvorfor.
  it('lar et spørsmål som venter på tilgang, stå uten faglig utfall', async () => {
    await openSection()
    const entry = (await screen.findByText('Hvor godt virker midlet hos barn og unge?')).closest(
      'li',
    ) as HTMLElement
    const inside = within(entry)

    expect(inside.getByText('Venter på tilgang')).toBeVisible()
    expect(inside.getByText('Uavklart relevans')).toBeVisible()
    expect(inside.getByText(/Dette er en tilgangsbegrensning, ikke en konklusjon/)).toBeVisible()
    expect(inside.getByText(/betalingsmur/i)).toBeVisible()

    expect(inside.queryByText('Besvart')).toBeNull()
    expect(inside.queryByText('Utilstrekkelig evidens')).toBeNull()
    expect(inside.queryByText('Ingen kvalifiserende studier')).toBeNull()
    expect(inside.queryByText('Ikke relevant')).toBeNull()
  })

  it('viser usikkerhet, begrensninger, kontrollerte felter og kilder først bak «Vis detaljene»', async () => {
    await openSection()
    const entry = (
      await screen.findByText('Hvor godt virker midlet ved depresjon hos voksne?')
    ).closest('li') as HTMLElement

    expect(within(entry).queryByText(/Konfidensintervallet er bredt/)).toBeNull()
    fireEvent.click(within(entry).getByRole('button', { name: 'Vis detaljene' }))

    const inside = within(entry)
    expect(inside.getByText(/Konfidensintervallet er bredt/)).toBeVisible()
    expect(inside.getByText(/Ett søk nådde ikke fram, og er åpent/)).toBeVisible()
    expect(inside.getByText(/statement, certainty/)).toBeVisible()
    expect(inside.getByText(/Sertraline versus placebo in adults/)).toBeVisible()
    expect(inside.getByText(/Forskningsfunn/)).toBeVisible()
    expect(inside.getByText(/Lav sikkerhet/)).toBeVisible()
  })
})

// ----------------------------------------------------------------------------
// Den redaksjonelle kontrollen
// ----------------------------------------------------------------------------

describe('den redaksjonelle kontrollen', () => {
  async function openDetail() {
    renderAt(`/monografi/${REFERENCE}`, gateway)
    fireEvent.click(await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ }))
    const entry = (
      await screen.findByText('Hvor godt virker midlet ved depresjon hos voksne?')
    ).closest('li') as HTMLElement
    fireEvent.click(within(entry).getByRole('button', { name: 'Vis detaljene' }))
    return within(entry)
  }

  const editAnswer = vi.fn(() => Promise.resolve())
  // Signaturen er skrevet ut for at `toHaveBeenCalledWith` skal kunne
  // typekontrolleres: en `vi.fn(() => …)` har en tom argumentliste.
  const lockAnswer = vi.fn((needReference: string, reason: string) => {
    void needReference
    void reason
    return Promise.resolve()
  })
  const gateway = monograph({ editAnswer, lockAnswer })

  it('lar en redaktør rette teksten med en begrunnelse, uten kode eller SQL', async () => {
    editAnswer.mockClear()
    const inside = await openDetail()

    fireEvent.change(inside.getByLabelText('Rett teksten'), {
      target: { value: 'Effekten er liten sammenliknet med placebo.' },
    })
    fireEvent.change(inside.getByLabelText('Begrunnelse'), {
      target: { value: 'Presisert etter gjennomgang av grunnlaget.' },
    })
    fireEvent.click(inside.getByRole('button', { name: 'Lagre rettelsen' }))

    await waitFor(() => {
      expect(editAnswer).toHaveBeenCalledWith({
        needReference: 'n1',
        statement: 'Effekten er liten sammenliknet med placebo.',
        changeReason: 'Presisert etter gjennomgang av grunnlaget.',
      })
    })
  })

  it('lar en redaktør låse et svar mot automatisk overskriving', async () => {
    lockAnswer.mockClear()
    const inside = await openDetail()
    fireEvent.click(inside.getByRole('button', { name: 'Lås mot automatisk overskriving' }))
    // Låsingen bærer en begrunnelse: en lås uten grunn ville vært en endring
    // ingen kan etterprøve.
    await waitFor(() => {
      expect(lockAnswer).toHaveBeenCalledWith('n1', expect.stringMatching(/\S/))
    })
  })

  // Låst innhold skjermes ikke mot synlig kritikk: ny evidens blir et avvik som
  // står i flaten, med sin egen begrunnelse og sin egen kilde.
  it('viser ny evidens mot et låst svar som et synlig avvik med to utveier', async () => {
    const decideProposal = vi.fn(() => Promise.resolve())
    renderAt(`/monografi/${REFERENCE}`, monograph({ decideProposal }))

    const avvik = within(
      await screen.findByRole('region', { name: 'Avvik som venter på en avgjørelse' }),
    )
    expect(avvik.getByText('Nytt kontrollert grunnlag for et låst svar')).toBeVisible()
    expect(avvik.getByText(/peker i en annen retning enn det låste svaret/)).toBeVisible()
    expect(avvik.getByText(/Sertraline reconsidered/)).toBeVisible()

    fireEvent.click(avvik.getByRole('button', { name: 'Godta' }))
    await waitFor(() => {
      expect(decideProposal).toHaveBeenCalledWith('p1', true, '')
    })
  })

  it('sier at ingen avvik venter, framfor å se ut som en feil', async () => {
    renderAt(
      `/monografi/${REFERENCE}`,
      monograph({ proposals: () => Promise.resolve(parseMonographProposals({ proposals: [] })) }),
    )
    expect(await screen.findByText('Ingen åpne avvik.')).toBeVisible()
  })
})

// ----------------------------------------------------------------------------
// Det Antidep venter på — og det som aldri skal vises
// ----------------------------------------------------------------------------

describe('originalmaterialet Antidep venter på', () => {
  it('viser én samlet forespørsel med identitet og faglig grunn', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    const venter = within(
      await screen.findByRole('region', { name: 'Originalmateriale Antidep venter på' }),
    )
    expect(venter.getByRole('heading', { name: 'Sertraline in adolescents' })).toBeVisible()
    expect(venter.getByText(/Testforfatter B mfl./)).toBeVisible()
    expect(venter.getByText(/Trengs for spørsmålet om effekt hos barn og unge/)).toBeVisible()
  })

  // En betalingsmur er en tilgangsbegrensning. Flaten sier det med så mange ord,
  // slik at ingen leser den som en faglig utelukkelse (SOURCE_POLICY.md).
  it('kaller en betalingsmur en tilgangsbegrensning og ingen faglig utelukkelse', async () => {
    renderAt(`/monografi/${REFERENCE}`)
    expect(
      await screen.findByText(/Dette er en tilgangsbegrensning og ingen faglig utelukkelse/),
    ).toBeVisible()
  })

  it('sier at ingenting venter, når ingenting venter', async () => {
    renderAt(
      `/monografi/${REFERENCE}`,
      monograph({
        requests: () =>
          Promise.resolve(
            parseMonographRequests({ research_full_text: [], authority_documents: [] }),
          ),
      }),
    )
    expect(
      await screen.findByText('Antidep venter ikke på noe originalmateriale nå.'),
    ).toBeVisible()
  })
})

describe('det som aldri skal stå på flaten', () => {
  it('viser ingen intern id, jobbnøkkel, agentrolle eller filsti', async () => {
    const { container } = renderAt(`/monografi/${REFERENCE}`)
    fireEvent.click(await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ }))
    fireEvent.click(
      (await screen.findAllByRole('button', { name: 'Vis detaljene' }))[0] as HTMLElement,
    )

    const text = container.textContent ?? ''
    expect(text).not.toContain(INTERNAL_ID)
    expect(text).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)
    expect(text).not.toContain('source_discovery')
    expect(text).not.toContain('monograph_answer')
    expect(text).not.toContain('sha256')
    expect(text).not.toContain('agent_run')
    expect(text).not.toContain('job_key')
  })

  // Det private originaldokumentet og det interne utdraget er ikke i
  // kontrakten flaten leser, og kommer derfor ikke gjennom. Prøven leser hele
  // siden framfor ett felt: en lekkasje ville dukket opp et sted ingen tenkte
  // på.
  it('viser verken originaldokument eller ordrett internt utdrag', async () => {
    const { container } = renderAt(`/monografi/${REFERENCE}`)
    fireEvent.click(await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ }))
    fireEvent.click(
      (await screen.findAllByRole('button', { name: 'Vis detaljene' }))[0] as HTMLElement,
    )

    const text = container.textContent ?? ''
    expect(text).not.toContain('%PDF')
    expect(text).not.toContain('base64')
    expect(text).not.toContain('document_base64')
    expect(text).not.toMatch(/«[^»]{200,}»/)
  })
})

// ----------------------------------------------------------------------------
// Mobil og desktop
// ----------------------------------------------------------------------------

describe('på telefon og på skjerm', () => {
  const widths = [
    { name: 'telefon', width: 360 },
    { name: 'skjerm', width: 1440 },
  ]

  for (const { name, width } of widths) {
    // Samme innhold på begge bredder. jsdom legger ingen layout på siden, så
    // prøven kan ikke måle brytningen — den kan derimot vise at ingen tekst,
    // ingen tilstand og ingen handling *forsvinner*, som er feilen en egen
    // mobilvisning pleier å innføre.
    it(`viser de samme tallene, tilstandene og handlingene på ${name}`, async () => {
      window.innerWidth = width
      window.dispatchEvent(new Event('resize'))

      renderAt(`/monografi/${REFERENCE}`)
      const dekning = within(await screen.findByRole('region', { name: 'Dekning' }))
      expect(dekning.getByText('spørsmål i alt')).toBeVisible()
      expect(dekning.getByText(/Ingen av disse er en konklusjon om kunnskapen/)).toBeVisible()
      expect(await screen.findByText(/Dette er et delvis utkast/)).toBeVisible()

      fireEvent.click(await screen.findByRole('button', { name: /Effekt — 1 av 2 besvart/ }))
      const entry = (await screen.findByText('Hvor godt virker midlet hos barn og unge?')).closest(
        'li',
      ) as HTMLElement
      expect(within(entry).getByText('Venter på tilgang')).toBeVisible()
      expect(within(entry).getByRole('button', { name: 'Vis detaljene' })).toBeVisible()
    })
  }
})
