// ============================================================================
// Den redaksjonelle revisjonsflaten, prøvd som spørsmål et menneske ville stilt
//
//   * ser en redaktør hvilke påstander som har fått ny forskning?
//   * kan oppgaven åpnes uten å kjenne én eneste teknisk identifikator?
//   * står påstanden og den nye forskningen der, i klartekst?
//   * lekker flaten en uuid, en jobbnøkkel, en agentrolle eller et avtrykk?
//   * kan redaktøren beslutte revisjon, og få vite hva som skjer videre?
//   * blir «endrer ikke påstanden» stoppet når begrunnelsen mangler?
//   * sendes evidensgrunnlaget uendret tilbake, slik at en foreldet beslutning
//     kan avvises?
//   * står den åpne arbeidsoversikten med en forståelig, ikke-teknisk setning?
// ============================================================================

import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'

import { AppLayout } from './App'
import { GatewayFailure } from './gateway'
import type { ClaimRevisionGateway } from './claim-revision-gateway'
import type { WorkBoardGateway } from './work-board-gateway'
import {
  parseClaimRevisionOutcome,
  parseClaimRevisionQueue,
  parseClaimRevisionTask,
} from '../lib/claim-revision'
import { parseWorkBoard } from '../lib/work-board'

const REFERENCE = '9f2c1a4b8e6d0c3a5b7f9e1d'
const BASIS = `sha256-v1:${'b'.repeat(64)}`

const TASK = {
  reference: REFERENCE,
  subject_drug: 'sertralin',
  topic: 'søvnlengde',
  statement: 'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
  scope: 'Gjelder voksne med depressiv lidelse.',
  uncertainty_summary: 'Grunnlaget er lite.',
  revision_number: 1,
  published: true,
  newer_unpublished_revision: false,
  certainty_level: 'low',
  existing_evidence_count: 1,
  new_article_count: 2,
  new_finding_count: 3,
  noticed_at: '2026-09-30T09:00:00+00:00',
  evidence_basis: BASIS,
}

// To artikler, og tre funn: den første studien bærer to av dem. En liste som
// viste funn som om de var artikler, ville vist den samme studien to ganger.
const NEW_EVIDENCE = [
  {
    article_title: 'Sertraline and sleep over twelve weeks',
    article_authors: 'Testforfatter B m.fl.',
    published_year: 2026,
    findings: [
      {
        study_design: 'randomized_controlled_trial',
        population: 'voksne med depressiv lidelse',
        population_detail: 'Voksne med moderat depresjon.',
        participants: 120,
        finding: 'Kortere søvn ved tolv uker.',
        direction: 'decrease',
        effect_measure: 'mean_change',
        estimate: -0.4,
        estimate_unit: 'kg',
        ci_lower: -0.9,
        ci_upper: 0.1,
        ci_level_percent: 95,
        limitations: 'Åpen oppfølging.',
      },
      {
        study_design: 'randomized_controlled_trial',
        population: 'voksne med depressiv lidelse',
        population_detail: 'Voksne med moderat depresjon.',
        participants: 120,
        finding: 'Flere oppvåkninger ved tolv uker.',
        direction: 'increase',
        effect_measure: null,
        estimate: null,
        estimate_unit: null,
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        limitations: null,
      },
    ],
  },
  {
    article_title: 'A third look at sertraline and sleep',
    article_authors: 'Testforfatter C m.fl.',
    published_year: null,
    findings: [
      {
        study_design: 'randomized_controlled_trial',
        population: null,
        population_detail: 'Voksne.',
        participants: null,
        finding: 'Ingen klar forskjell.',
        direction: 'no_clear_difference',
        effect_measure: null,
        estimate: null,
        estimate_unit: null,
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        limitations: null,
      },
    ],
  },
]

function claimRevision(overrides: Partial<ClaimRevisionGateway> = {}): ClaimRevisionGateway {
  return {
    listQueue: () => Promise.resolve(parseClaimRevisionQueue([TASK])),
    read: () => Promise.resolve(parseClaimRevisionTask({ ...TASK, new_evidence: NEW_EVIDENCE })),
    decide: () =>
      Promise.resolve(
        parseClaimRevisionOutcome({ reference: REFERENCE, decision: 'revise', recorded: true }),
      ),
    ...overrides,
  }
}

describe('køen over påstander som har fått ny forskning', () => {
  it('viser påstanden, virkestoffet og hvor mye nytt som er kommet til', async () => {
    render(
      <MemoryRouter initialEntries={['/ny-evidens']}>
        <AppLayout claimRevision={claimRevision()} />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', {
        level: 1,
        name: 'Påstander som har fått ny forskning',
      }),
    ).toBeVisible()
    expect(
      screen.getByRole('link', {
        name: 'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
      }),
    ).toBeVisible()
    expect(screen.getByText('sertralin — søvnlengde. Publisert og i bruk nå.')).toBeVisible()
    expect(screen.getByText(/2 nye forskningsartikler med 3 funn/)).toBeVisible()
  })

  // En tom kø er ikke en avvisning: den betyr at ingen påstand venter på noe
  // fra deg akkurat nå.
  it('sier at ingenting venter, framfor å se ut som en feil', async () => {
    render(
      <MemoryRouter initialEntries={['/ny-evidens']}>
        <AppLayout claimRevision={claimRevision({ listQueue: () => Promise.resolve([]) })} />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/Ingen påstander venter på en avgjørelse nå/)).toBeVisible()
  })

  it('sier hva som mangler når den innloggede ikke har redaktørmandat', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={['/ny-evidens']}>
        <AppLayout
          claimRevision={claimRevision({
            listQueue: () =>
              Promise.reject(
                new GatewayFailure(
                  'Å avgjøre om en påstand skal skrives om, er en redaksjonell avgjørelse, og ' +
                    'krever redaktørmandat for fagområdet. Ta kontakt med en administrator hvis ' +
                    'du skulle hatt det.',
                  'not_authorized',
                  'clinical_content',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/krever redaktørmandat for fagområdet/)).toBeVisible()
    spy.mockRestore()
  })
})

describe('den ene oppgaven, og avgjørelsen', () => {
  it('viser påstanden slik den står, og hver ny artikkel', async () => {
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout claimRevision={claimRevision()} />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', { level: 1, name: 'sertralin — søvnlengde' }),
    ).toBeVisible()
    const dagens = within(screen.getByRole('region', { name: 'Det Antidep sier i dag' }))
    expect(
      dagens.getByText('Sertralin er forbundet med noe lengre søvn ved åtte uker.'),
    ).toBeVisible()
    expect(dagens.getByText(/Evidensen er vurdert som lav/)).toBeVisible()

    const ny = within(screen.getByRole('region', { name: 'Dette er kommet til' }))
    // To artikler, ikke tre: den første bærer to av de tre funnene, og den skal
    // stå én gang med begge funnene under seg.
    expect(ny.getAllByRole('heading', { level: 3 })).toHaveLength(2)
    expect(
      ny.getByRole('heading', { level: 3, name: 'Sertraline and sleep over twelve weeks' }),
    ).toBeVisible()
    expect(ny.getAllByText(/Randomisert kontrollert studie/)).toHaveLength(3)
    expect(ny.getByText('Kortere søvn ved tolv uker.')).toBeVisible()
    expect(ny.getByText('Flere oppvåkninger ved tolv uker.')).toBeVisible()
    expect(ny.getByText('Kilden rapporterer en reduksjon.')).toBeVisible()
    // Bare det ene funnet oppgir en størrelse, og da står det bare én.
    expect(ny.getByText('Kilden fant ingen klar forskjell.')).toBeVisible()
    expect(ny.getAllByText(/Størrelse:/)).toHaveLength(1)
  })

  // Den siste bygde formuleringen er ikke nødvendigvis den i bruk. Sier flaten
  // at påstanden er publisert, må teksten over være den publiserte — og finnes
  // det en nyere som ikke er tatt i bruk, skal det stå eksplisitt.
  it('sier fra når en nyere formulering er bygget uten å være publisert', async () => {
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout
          claimRevision={claimRevision({
            read: () =>
              Promise.resolve(
                parseClaimRevisionTask({
                  ...TASK,
                  newer_unpublished_revision: true,
                  new_evidence: NEW_EVIDENCE,
                }),
              ),
          })}
        />
      </MemoryRouter>,
    )

    const dagens = within(await screen.findByRole('region', { name: 'Det Antidep sier i dag' }))
    expect(dagens.getByText(/En nyere formulering er allerede bygget/)).toBeVisible()
    expect(dagens.getByText(/Påstanden er publisert og i bruk nå/)).toBeVisible()
  })

  it('sier ingenting om en nyere formulering når det ikke finnes noen', async () => {
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout claimRevision={claimRevision()} />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'sertralin — søvnlengde' })
    expect(screen.queryByText(/En nyere formulering er allerede bygget/)).toBeNull()
  })

  // Akseptansekravet: ingen uuid, ingen jobbnøkkel, ingen agentrolle, ingen
  // modell og ingen avtrykk. Håndtaket står i adressen, aldri på skjermen.
  it('lekker ingen intern eller teknisk opplysning', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout claimRevision={claimRevision()} />
      </MemoryRouter>,
    )

    await screen.findByRole('heading', { level: 1, name: 'sertralin — søvnlengde' })
    const text = (container.textContent ?? '').toLowerCase()
    for (const teknisk of [
      'claim_synthesis',
      'evidence_assessment',
      'pipeline',
      'agent-handoff',
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
      REFERENCE,
      BASIS.toLowerCase(),
    ]) {
      expect(text).not.toContain(teknisk)
    }
  })

  // Beslutningen er bundet til nøyaktig det grunnlaget siden viste, og
  // avtrykket sendes uendret tilbake (ANTIDEP_CONSTITUTION.md regel 5).
  it('sender evidensgrunnlaget uendret tilbake med avgjørelsen', async () => {
    const decide = vi.fn(() =>
      Promise.resolve(
        parseClaimRevisionOutcome({ reference: REFERENCE, decision: 'revise', recorded: true }),
      ),
    )
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout claimRevision={claimRevision({ decide })} />
      </MemoryRouter>,
    )

    fireEvent.click(
      await screen.findByRole('button', { name: 'Skriv påstanden om med den nye forskningen' }),
    )

    await waitFor(() => {
      expect(decide).toHaveBeenCalledWith({
        reference: REFERENCE,
        decision: 'revise',
        seenEvidenceBasis: BASIS,
        note: '',
      })
    })
    expect(await screen.findByText(/Takk — Antidep skriver nå påstanden på nytt/)).toBeVisible()
  })

  // Begrunnelsen er det som gjør «endrer ikke påstanden» til en faglig
  // konklusjon. Uten den sendes ingenting.
  it('stopper konklusjonen om at ingenting endres, når begrunnelsen mangler', async () => {
    const decide = vi.fn(() =>
      Promise.resolve(
        parseClaimRevisionOutcome({ reference: REFERENCE, decision: 'set_aside', recorded: true }),
      ),
    )
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout claimRevision={claimRevision({ decide })} />
      </MemoryRouter>,
    )

    fireEvent.click(
      await screen.findByRole('button', { name: 'Den nye forskningen endrer ikke påstanden' }),
    )
    expect(
      await screen.findByText('Skriv kort hvorfor den nye forskningen ikke endrer påstanden.'),
    ).toBeVisible()
    expect(decide).not.toHaveBeenCalled()

    fireEvent.change(screen.getByLabelText(/Begrunnelse/), {
      target: { value: 'Peker samme vei som dagens formulering.' },
    })
    fireEvent.click(
      screen.getByRole('button', { name: 'Den nye forskningen endrer ikke påstanden' }),
    )

    await waitFor(() => {
      expect(decide).toHaveBeenCalledWith({
        reference: REFERENCE,
        decision: 'set_aside',
        seenEvidenceBasis: BASIS,
        note: 'Peker samme vei som dagens formulering.',
      })
    })
  })

  // Er grunnlaget endret mens siden sto åpen, avviser databasen. Flaten sier
  // hva som skal gjøres i stedet, og aldri hva databasen sa.
  it('ber om fersk tilstand når grunnlaget er endret under beina på redaktøren', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout
          claimRevision={claimRevision({
            decide: () =>
              Promise.reject(
                new GatewayFailure(
                  'Grunnlaget er endret siden du åpnet oppgaven, eller noen andre har allerede ' +
                    'avgjort den. Hent oppgaven på nytt, og ta stilling til det som faktisk ' +
                    'finnes nå.',
                  'rejected',
                  'clinical_content',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    fireEvent.click(
      await screen.findByRole('button', { name: 'Skriv påstanden om med den nye forskningen' }),
    )
    expect(await screen.findByText(/Grunnlaget er endret siden du åpnet oppgaven/)).toBeVisible()
    spy.mockRestore()
  })

  it('sier at oppgaven er avgjort av noen andre, framfor å vise en rå feil', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    render(
      <MemoryRouter initialEntries={[`/ny-evidens/${REFERENCE}`]}>
        <AppLayout
          claimRevision={claimRevision({
            read: () =>
              Promise.reject(
                new GatewayFailure(
                  'Denne oppgaven venter ikke lenger på en avgjørelse. Den kan være avgjort av ' +
                    'noen andre, eller den nye forskningen kan ha blitt trukket tilbake. Hent ' +
                    'listen på nytt.',
                  'not_found',
                  'clinical_content',
                ),
              ),
          })}
        />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/venter ikke lenger på en avgjørelse/)).toBeVisible()
    spy.mockRestore()
  })
})

describe('den åpne arbeidsoversikten', () => {
  // Akseptansekravet fra issue #99, for den nye tilstanden: vanlig språk,
  // planlagt arbeid, ingen intern verdi, og ingenting som ser ut som en feil.
  it('sier at ny kunnskap venter på en redaktør, i vanlig språk', async () => {
    const board: WorkBoardGateway = {
      list: () =>
        Promise.resolve(
          parseWorkBoard([
            {
              reference: 'e5',
              activity: 'claim_revision',
              status: 'planned',
              waiting_for: 'editorial_decision',
              subjects: ['sertralin'],
              updated_at: '2026-09-30T09:00:00+00:00',
            },
          ]),
        ),
    }
    const { container } = render(
      <MemoryRouter initialEntries={['/arbeid']}>
        <AppLayout workBoard={board} />
      </MemoryRouter>,
    )

    const planlagt = within(await screen.findByRole('region', { name: 'Planlagt' }))
    expect(
      planlagt.getByText('Vurdere om ny forskning endrer en påstand Antidep allerede har'),
    ).toBeVisible()
    expect(
      planlagt.getByText(/venter på at en redaktør avgjør om påstanden skal oppdateres/),
    ).toBeVisible()
    // Ingen tilstand som ser ut som en feil, og ingen intern verdi.
    expect(screen.queryByRole('region', { name: 'Stoppet' })).toBeNull()
    const text = (container.textContent ?? '').toLowerCase()
    for (const teknisk of ['claim_revision', 'sha256', 'uuid', 'påstand nummer', 'agent']) {
      expect(text).not.toContain(teknisk)
    }
  })
})
