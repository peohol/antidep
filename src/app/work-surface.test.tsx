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
import {
  parseCapabilities,
  parseRequestOptions,
  parseRequestResult,
} from '../lib/full-text-request'
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
    waiting_for: 'full_text',
    subjects: ['sertralin'],
    updated_at: '2026-09-28T09:00:00+00:00',
  },
  {
    reference: 'b2',
    activity: 'findings',
    status: 'in_progress',
    waiting_for: null,
    subjects: ['mirtazapin'],
    updated_at: '2026-09-29T10:00:00+00:00',
  },
  {
    reference: 'c3',
    activity: 'claim',
    status: 'failed',
    waiting_for: null,
    subjects: [],
    updated_at: '2026-09-29T11:00:00+00:00',
  },
  {
    reference: 'd4',
    activity: 'assessment',
    status: 'done',
    waiting_for: null,
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
    capabilities: () => Promise.resolve(parseCapabilities({ may_request: true, may_upload: true })),
    requestOptions: () =>
      Promise.resolve(
        parseRequestOptions({
          drugs: ['sertralin', 'mirtazapin'],
          outcomes: ['vektendring'],
          populations: ['voksne med depressiv lidelse'],
        }),
      ),
    request: () =>
      Promise.resolve(parseRequestResult({ requested: true, state: 'open', title: 'Ny artikkel' })),
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

describe('bestillingen av en artikkel Antidep mangler', () => {
  it('ber bare om det en redaktør kan svare på uten å slå opp noe teknisk', async () => {
    render(
      <MemoryRouter initialEntries={['/be-om-artikkel']}>
        <AppLayout fullText={fullText()} />
      </MemoryRouter>,
    )

    expect(await screen.findByLabelText('Tittel')).toBeVisible()
    expect(screen.getByLabelText('Forfattere')).toBeVisible()
    expect(screen.getByLabelText('DOI')).toBeVisible()
    expect(screen.getByRole('group', { name: 'Virkestoff' })).toBeVisible()
    expect(screen.getByRole('group', { name: 'Endepunkt' })).toBeVisible()
    expect(screen.getByRole('checkbox', { name: 'sertralin' })).toBeVisible()

    // Ingen uuid, ingen hash, ingen oppskrift, ingen jobbnøkkel, ingen
    // agentrolle, ingen modell, ingen kjører og ingen terminalkommando.
    const flate = document.body.textContent ?? ''
    for (const teknisk of [
      'uuid',
      'sha256',
      'npm run',
      'pipeline',
      'evidence_extraction',
      'request_missing_full_text',
      'source_version',
    ]) {
      expect(flate).not.toContain(teknisk)
    }
  })

  it('sender bestillingen med navn, og aldri med en id', async () => {
    const request: FullTextGateway['request'] = vi.fn(() =>
      Promise.resolve(
        parseRequestResult({ requested: true, state: 'open', title: 'Sertralin og vekt' }),
      ),
    )
    render(
      <MemoryRouter initialEntries={['/be-om-artikkel']}>
        <AppLayout fullText={fullText({ request })} />
      </MemoryRouter>,
    )

    fireEvent.change(await screen.findByLabelText('Tittel'), {
      target: { value: 'Sertralin og vekt' },
    })
    fireEvent.change(screen.getByLabelText('Forfattere'), {
      target: { value: 'Testforfatter m.fl.' },
    })
    fireEvent.change(screen.getByLabelText('DOI'), {
      target: { value: 'https://doi.org/10.1234/ABC' },
    })
    fireEvent.click(screen.getByRole('checkbox', { name: 'sertralin' }))
    fireEvent.click(screen.getByRole('checkbox', { name: 'vektendring' }))
    fireEvent.click(screen.getByRole('button', { name: 'Be om artikkelen' }))

    await waitFor(() => {
      expect(request).toHaveBeenCalledTimes(1)
    })
    const [draft] = vi.mocked(request).mock.calls[0] ?? []
    expect(draft?.drugs).toEqual(['sertralin'])
    expect(draft?.outcomes).toEqual(['vektendring'])
    expect(await screen.findByText(/venter nå på «Sertralin og vekt»/)).toBeVisible()
  })

  it('sier hva som mangler før den sender noe som uansett ville blitt avvist', async () => {
    const request: FullTextGateway['request'] = vi.fn(() =>
      Promise.resolve(parseRequestResult({ requested: true, state: 'open', title: 'x' })),
    )
    render(
      <MemoryRouter initialEntries={['/be-om-artikkel']}>
        <AppLayout fullText={fullText({ request })} />
      </MemoryRouter>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Be om artikkelen' }))
    expect(await screen.findByText(/Skriv artikkelens tittel/)).toBeVisible()
    expect(request).not.toHaveBeenCalled()
  })

  it('viser ikke skjemaet til den som ikke kan bestille', async () => {
    // Et skjema vist til en admin ville bedt dem gjøre noe kallet uansett måtte
    // avvise — og en avvisning på noe man ikke gjorde galt, er teknisk støy.
    render(
      <MemoryRouter initialEntries={['/be-om-artikkel']}>
        <AppLayout
          fullText={fullText({
            capabilities: () =>
              Promise.resolve(parseCapabilities({ may_request: false, may_upload: true })),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/krever redaktørmandat/)).toBeVisible()
    expect(screen.queryByLabelText('Tittel')).toBeNull()
  })

  it('viser flatens egen setning når bestillingen ikke gikk gjennom', async () => {
    setTechnicalSink(() => {})
    render(
      <MemoryRouter initialEntries={['/be-om-artikkel']}>
        <AppLayout
          fullText={fullText({
            request: () =>
              Promise.reject(
                new GatewayFailure(
                  'Antidep venter allerede på denne artikkelen med en annen avgrensning.',
                  'rejected',
                  'full_text_intake',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    fireEvent.change(await screen.findByLabelText('Tittel'), { target: { value: 'En artikkel' } })
    fireEvent.change(screen.getByLabelText('Forfattere'), { target: { value: 'En forfatter' } })
    fireEvent.change(screen.getByLabelText('DOI'), { target: { value: '10.1234/abc' } })
    fireEvent.click(screen.getByRole('checkbox', { name: 'sertralin' }))
    fireEvent.click(screen.getByRole('checkbox', { name: 'vektendring' }))
    fireEvent.click(screen.getByRole('button', { name: 'Be om artikkelen' }))

    expect(await screen.findByText(/venter allerede på denne artikkelen/)).toBeVisible()
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

  it('stopper en for stor fil i flaten, uten å lese eller sende den', async () => {
    const submit: FullTextGateway['submit'] = vi.fn(() =>
      Promise.resolve(parseFullTextSubmission({ accepted: true })),
    )
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout fullText={fullText({ submit })} />
      </MemoryRouter>,
    )

    const felt = await screen.findByLabelText('Fulltekst som PDF')
    // En «fil» som er større enn grensen. Innholdet er tomt med vilje: prøven
    // gjelder at flaten ser på størrelsen *før* den leser noe som helst.
    const svær = new File([], 'svaer.pdf', { type: 'application/pdf' })
    Object.defineProperty(svær, 'size', { value: 67_108_865 })
    fireEvent.change(felt, { target: { files: [svær] } })

    expect(await screen.findByText(/større enn 64 MB/)).toBeVisible()
    expect(submit).not.toHaveBeenCalled()
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

  // Dette er den ene tilstanden som ikke må bli en oppgave. Står Antidep fast
  // på et driftsproblem, skal innboksen si at ingenting skal gjøres — og
  // særlig ikke be om filen en gang til.
  it('ber ikke om en ny fil når det er driften som står, ikke filen', async () => {
    render(
      <MemoryRouter initialEntries={['/fulltekst']}>
        <AppLayout
          fullText={fullText({
            listInbox: () =>
              Promise.resolve(parseFullTextInbox([{ ...INBOX_WAITING, state: 'blocked' }])),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/fortsetter av seg selv/)).toBeVisible()
    expect(screen.getByText(/trenger ikke gjøre noe/)).toBeVisible()
    expect(screen.queryByLabelText('Fulltekst som PDF')).not.toBeInTheDocument()
    expect(screen.queryByText(/Last opp fullteksten/)).not.toBeInTheDocument()
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
