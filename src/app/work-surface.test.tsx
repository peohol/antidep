// ============================================================================
// De tre nye flatene, prøvd mot akseptansekravene i issue #99
//
// Prøvene er skrevet som spørsmål et menneske ville stilt om produktet, og ikke
// om implementasjonen:
//
//   * ser en uinnlogget bruker hva Antidep arbeider med, uten å se noe teknisk?
//   * står «venter på fulltekst» som planlagt arbeid?
//   * kan status leses uten å se farge?
//   * kan en redaktør laste opp en PDF uten å oppgi en eneste teknisk verdi?
//   * blir en avvist fil en beskjed om hva som kan gjøres i stedet?
//   * ser en admin hvilket område som har problemer — og aldri diagnosen?
//   * finnes kjører-, modell- og filtransportkontrollene noe sted i produktet?
// ============================================================================

import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { AppLayout } from './App'
import { GatewayFailure, setTechnicalSink } from './gateway'
import type { FullTextGateway } from './full-text-gateway'
import type { TechnicalGateway } from './technical-gateway'
import type { WorkBoardGateway } from './work-board-gateway'
import { parseFullTextInbox, parseFullTextSubmission } from '../lib/full-text-inbox'
import { parseTechnicalProblemSummary, parseTechnicalProblems } from '../lib/technical-problems'
import { parseWorkBoard } from '../lib/work-board'

afterEach(() => {
  setTechnicalSink(null)
})

const BOARD_ROWS = [
  {
    reference: 'a1',
    activity: 'full_text',
    status: 'planned',
    waiting_for_full_text: true,
    subjects: ['sertralin'],
    updated_at: '2026-09-28T09:00:00+00:00',
  },
  {
    reference: 'b2',
    activity: 'findings',
    status: 'in_progress',
    waiting_for_full_text: false,
    subjects: ['mirtazapin'],
    updated_at: '2026-09-29T10:00:00+00:00',
  },
  {
    reference: 'c3',
    activity: 'claim',
    status: 'failed',
    waiting_for_full_text: false,
    subjects: [],
    updated_at: '2026-09-29T11:00:00+00:00',
  },
  {
    reference: 'd4',
    activity: 'assessment',
    status: 'done',
    waiting_for_full_text: false,
    subjects: ['sertralin'],
    updated_at: '2026-09-25T08:00:00+00:00',
  },
]

function workBoard(overrides: Partial<WorkBoardGateway> = {}): WorkBoardGateway {
  return { list: () => Promise.resolve(parseWorkBoard(BOARD_ROWS)), ...overrides }
}

const INBOX_WAITING = {
  reference: 'r1',
  title: 'Sertraline and weight change over 52 weeks',
  authors: 'Fava m.fl.',
  published_year: 2000,
  state: 'needs_upload',
  previous_rejection: null,
}

const INBOX_PROCESSING = {
  reference: 'r2',
  title: 'Mirtazapine in older adults',
  authors: 'Versiani m.fl.',
  published_year: null,
  state: 'processing',
  previous_rejection: null,
}

const INBOX_ROWS = [INBOX_WAITING, INBOX_PROCESSING]

function fullText(overrides: Partial<FullTextGateway> = {}): FullTextGateway {
  return {
    listInbox: () => Promise.resolve(parseFullTextInbox(INBOX_ROWS)),
    submit: () => Promise.resolve(parseFullTextSubmission({ accepted: true })),
    ...overrides,
  }
}

const PROBLEM_ROWS = [
  {
    reference: 'p1',
    area: 'automatic_task',
    first_seen_at: '2026-09-28T09:00:00+00:00',
    last_seen_at: '2026-09-29T09:00:00+00:00',
    occurrence_count: 3,
    ongoing: true,
    resolved_at: null,
  },
  {
    reference: 'p2',
    area: 'agent_service',
    first_seen_at: '2026-09-20T09:00:00+00:00',
    last_seen_at: '2026-09-21T09:00:00+00:00',
    occurrence_count: 1,
    ongoing: false,
    resolved_at: '2026-09-21T10:00:00+00:00',
  },
]

function technical(overrides: Partial<TechnicalGateway> = {}): TechnicalGateway {
  return {
    list: () => Promise.resolve(parseTechnicalProblems(PROBLEM_ROWS)),
    summary: () => Promise.resolve(parseTechnicalProblemSummary({ visible: false, unresolved: 0 })),
    ...overrides,
  }
}

describe('den åpne arbeidsoversikten', () => {
  it('viser hva Antidep arbeider med, uten innlogging', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout workBoard={workBoard()} />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', { level: 1, name: 'Dette arbeider Antidep med' }),
    ).toBeVisible()
    expect(await screen.findByRole('heading', { level: 2, name: 'Pågår nå' })).toBeVisible()
    expect(screen.getByRole('heading', { level: 2, name: 'Planlagt' })).toBeVisible()
    expect(screen.getByRole('heading', { level: 2, name: 'Stoppet' })).toBeVisible()
    expect(screen.getByRole('heading', { level: 2, name: 'Fullført' })).toBeVisible()
  })

  // Akseptansekravet: «Venter på fulltekst» vises som planlagt arbeid.
  it('viser en manglende artikkel som planlagt arbeid som venter på fulltekst', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout workBoard={workBoard()} />
      </MemoryRouter>,
    )

    const planlagt = within(await screen.findByRole('region', { name: 'Planlagt' }))
    expect(planlagt.getByText('Venter på fulltekst')).toBeVisible()
    expect(planlagt.getByText('Skaffe fullteksten til en forskningsartikkel')).toBeVisible()
  })

  // Akseptansekravet: status skal kunne leses uten farge. Hver tilstand har en
  // tekstlig etikett, og etikettene er forskjellige fra hverandre.
  it('uttrykker status med tekst og ikke med farge alene', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout workBoard={workBoard()} />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'Dette arbeider Antidep med' })
    for (const etikett of ['Planlagt', 'Pågår', 'Stoppet', 'Fullført']) {
      expect(screen.getAllByText(etikett).length).toBeGreaterThan(0)
    }
  })

  // Akseptansekravet: ingen interne id-er, agentroller, modellnavn,
  // runner-begreper, databasebegreper, tokens, JSON eller rå feilmeldinger.
  it('lekker ingen intern eller teknisk opplysning', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout workBoard={workBoard()} />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'Dette arbeider Antidep med' })
    const text = container.textContent ?? ''
    for (const teknisk of [
      'evidence_extraction',
      'claim_synthesis',
      'evidence_assessment',
      'pipeline',
      'agent_role',
      'lease',
      'runner',
      'kjører',
      'modell',
      'sha256',
      'uuid',
      'json',
      'rpc',
      'sqlstate',
    ]) {
      expect(text.toLowerCase()).not.toContain(teknisk)
    }
    // Referansene er håndtak i nøkler, ikke noe som står på skjermen.
    expect(text).not.toContain('a1')
    expect(text).not.toContain('d4')
  })

  it('viser en stabil menneskelig setning når Antidep ikke svarer', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout
          workBoard={workBoard({
            // Slik en gateway faktisk avviser: setningen er allerede Antideps
            // egen, og den rå årsaken har gått til observability.
            list: () =>
              Promise.reject(
                new GatewayFailure(
                  'Antidep får ikke hentet arbeidsoversikten akkurat nå. Prøv igjen om litt.',
                  'unavailable',
                  'work_queue',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(
      await screen.findByText(
        'Antidep får ikke hentet arbeidsoversikten akkurat nå. Prøv igjen om litt.',
      ),
    ).toBeVisible()
    spy.mockRestore()
  })

  // Og motsatt: kommer en feil denne veien som *ikke* er en gateway-avvisning —
  // en programmeringsfeil, en avbrutt forespørsel — skal siden fortsatt ikke
  // vise teksten dens (issue #99, punkt 8).
  it('viser aldri en rå feiltekst, heller ikke fra en uventet feil', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout
          workBoard={workBoard({
            list: () => Promise.reject(new TypeError('Failed to fetch https://db.example/rpc')),
          })}
        />
      </MemoryRouter>,
    )

    expect(
      await screen.findByText('Antidep svarte ikke akkurat nå. Prøv igjen om litt.'),
    ).toBeVisible()
    expect(screen.queryByText(/Failed to fetch/)).not.toBeInTheDocument()
    spy.mockRestore()
  })
})

describe('fulltekstinnboksen', () => {
  it('ber om én ting: riktig PDF til en artikkel som er navngitt i klartekst', async () => {
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout fullText={fullText()} />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', { level: 3, name: INBOX_WAITING.title }),
    ).toBeVisible()
    expect(screen.getByText('Fava m.fl. (2000)')).toBeVisible()
    expect(screen.getByLabelText('Fulltekst som PDF')).toBeVisible()
    // Artikkelen som allerede er levert, ber ikke om noe.
    expect(
      screen.getByText('Antidep arbeider med filen du lastet opp. Du trenger ikke gjøre noe mer.'),
    ).toBeVisible()
  })

  it('lar Antidep gjøre alt det tekniske selv når filen er valgt', async () => {
    const submit: FullTextGateway['submit'] = vi.fn(() =>
      Promise.resolve(parseFullTextSubmission({ accepted: true })),
    )
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout fullText={fullText({ submit })} />
      </MemoryRouter>,
    )

    const felt = await screen.findByLabelText('Fulltekst som PDF')
    const fil = new File([new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d])], 'artikkel.pdf', {
      type: 'application/pdf',
    })
    fireEvent.change(felt, { target: { files: [fil] } })

    await waitFor(() => {
      expect(submit).toHaveBeenCalledTimes(1)
    })
    // Referansen er databasens eget håndtak, og bytene er filens egne. Ingen
    // hash, ingen oppskrift og ingen adresse sendes av flaten.
    const [reference, document] = vi.mocked(submit).mock.calls[0] ?? []
    expect(reference).toBe('r1')
    expect(document).toBeInstanceOf(Uint8Array)
    expect(await screen.findByText(/Antidep har fått filen/)).toBeVisible()
  })

  it('gjør en avvist fil til en beskjed om hva som kan gjøres i stedet', async () => {
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout
          fullText={fullText({
            listInbox: () =>
              Promise.resolve(
                parseFullTextInbox([{ ...INBOX_WAITING, previous_rejection: 'not_this_article' }]),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/så ikke ut til å være denne artikkelen/)).toBeVisible()
    // Grunnen er en produkttilstand, ikke en teknisk kode.
    expect(screen.queryByText(/not_this_article/)).not.toBeInTheDocument()
  })

  it('sier fra på vanlig norsk når mandatet mangler', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout
          fullText={fullText({
            listInbox: () =>
              Promise.reject(
                new GatewayFailure(
                  'Fulltekstinnboksen er for redaktører og administratorer. Ta kontakt med en ' +
                    'administrator hvis du skulle hatt tilgang.',
                  'not_authorized',
                  'full_text_intake',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/for redaktører og administratorer/)).toBeVisible()
    spy.mockRestore()
  })
})

describe('den tekniske problemoversikten', () => {
  it('sier hvilket område som har problemer, når, og om det pågår', async () => {
    render(
      <MemoryRouter initialEntries={['/tekniske-problemer']}>
        <AppLayout technical={technical()} />
      </MemoryRouter>,
    )

    expect(await screen.findByText('En automatisk oppgave har stoppet')).toBeVisible()
    expect(screen.getByText('Tilkoblingen til agenttjenesten virker ikke')).toBeVisible()
    expect(screen.getByRole('heading', { level: 2, name: 'Pågår nå' })).toBeVisible()
    expect(screen.getByRole('heading', { level: 2, name: 'Løst tidligere' })).toBeVisible()
  })

  it('viser ingen rå diagnose, og ingen teknisk verdi i det hele tatt', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={['/tekniske-problemer']}>
        <AppLayout technical={technical()} />
      </MemoryRouter>,
    )

    await screen.findByText('En automatisk oppgave har stoppet')
    const text = (container.textContent ?? '').toLowerCase()
    for (const teknisk of ['sqlstate', 'jwt', 'postgrest', 'stack', 'uuid', 'pipeline', 'rpc']) {
      expect(text).not.toContain(teknisk)
    }
  })

  it('avviser en kaller uten admin-mandat med en setning om nettopp det', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={['/tekniske-problemer']}>
        <AppLayout
          technical={technical({
            list: () =>
              Promise.reject(
                new GatewayFailure(
                  'Den tekniske problemoversikten er for administratorer.',
                  'not_authorized',
                  'work_queue',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/for administratorer/)).toBeVisible()
    spy.mockRestore()
  })
})

describe('merket i navigasjonen', () => {
  it('vises bare når en admin faktisk har et uløst problem', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout
          technical={technical({
            summary: () =>
              Promise.resolve(parseTechnicalProblemSummary({ visible: true, unresolved: 2 })),
          })}
          workBoard={workBoard()}
        />
      </MemoryRouter>,
    )

    const lenke = await screen.findByRole('link', { name: /Tekniske problemer/ })
    expect(lenke).toHaveAttribute('href', '/tekniske-problemer')
    // Merket bærer tallet og ordet, ikke bare en farge.
    expect(within(lenke).getByText('uløste')).toBeVisible()
    expect(lenke.textContent).toContain('2')
  })

  it('vises ikke for den som ikke er admin', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout technical={technical()} workBoard={workBoard()} />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'Dette arbeider Antidep med' })
    expect(screen.queryByRole('link', { name: /Tekniske problemer/ })).not.toBeInTheDocument()
  })

  it('vises ikke når tellingen ikke kunne hentes', async () => {
    render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout
          technical={technical({ summary: () => Promise.reject(new Error('svarte ikke')) })}
          workBoard={workBoard()}
        />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'Dette arbeider Antidep med' })
    expect(screen.queryByRole('link', { name: /Tekniske problemer/ })).not.toBeInTheDocument()
  })
})

describe('det tekniske arbeidet er ute av produktet', () => {
  // Akseptansekravet: ingen vanlig produktflate inneholder runner-registrering,
  // modellvalg, oppgavefilnedlasting eller agentsvaropplasting.
  it.each(['/', '/arbeid', '/fulltekst', '/tekniske-problemer'])(
    'har ingen kjører-, modell- eller filtransportkontroll på %s',
    async (path) => {
      const { container } = render(
        <MemoryRouter initialEntries={[path]}>
          <AppLayout fullText={fullText()} technical={technical()} workBoard={workBoard()} />
        </MemoryRouter>,
      )

      await waitFor(() => {
        expect(screen.getByRole('main')).toBeInTheDocument()
      })
      const text = (container.textContent ?? '').toLowerCase()
      for (const teknisk of [
        'registrer en kjører',
        'tilkoblingskode',
        'leverandør',
        'modellversjon',
        'last ned oppgave',
        'svar.json',
        'agentarbeid',
      ]) {
        expect(text).not.toContain(teknisk)
      }
      // Den ene filkontrollen som finnes, er opplastingen av en fulltekst.
      for (const felt of container.querySelectorAll('input[type="file"]')) {
        expect(felt.getAttribute('accept')).toContain('pdf')
      }
    },
  )
})
