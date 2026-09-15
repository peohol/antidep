import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'
import { AppLayout } from './App'
import type { CandidateGateway } from './candidate-gateway'
import { parseCandidateView } from '../lib/candidate-view'

const DIGEST = `sha256:${'a'.repeat(64)}`
const CANDIDATE = '11111111-1111-4111-8111-111111111111'

function kandidatsvar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    candidate_id: CANDIDATE,
    claim_revision_id: '22222222-2222-4222-8222-222222222222',
    candidate_digest: DIGEST,
    built_at: '2026-09-26T09:00:00+00:00',
    is_current: true,
    current_digest: DIGEST,
    experimental: true,
    published: false,
    content: {
      claim_revision: {
        statement: 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
        scope: 'Voksne i allmennpraksis.',
        subject_drug: 'sertralin',
        topic: 'vektendring',
        population: 'voksne med depressiv lidelse',
        direction: 'increase',
        uncertainty_summary: 'Grunnlaget er begrenset til én studie.',
      },
      evidence_assessment: {
        framework: 'grade',
        certainty_level: 'low',
        rationale: 'Én studie, alvorlig upresishet.',
      },
      evidence: [
        {
          evidence_item_id: '33333333-3333-4333-8333-333333333333',
          relationship_type: 'supports',
          directness: 'direct',
          outcome: 'vektendring',
          outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
          reported_direction: 'increase',
          estimate: '1.0',
          estimate_unit: 'percent',
          source: { title: 'Syntetisk artikkel om vektendring' },
          coverage: {
            required_check_fields: ['outcome', 'estimate', 'timepoint'],
            covered_check_fields: ['outcome', 'estimate'],
            grounded_check_fields: ['outcome', 'estimate'],
            grounding_machine_proved: false,
          },
          field_groundings: [
            {
              check_field: 'estimate',
              source_excerpt: 'Mean percent weight change was 1.0% at endpoint.',
              source_locator: 'RESULTS',
            },
          ],
          extraction_check: { outcome: 'verified' },
        },
      ],
      source_coverage: [
        {
          source_id: '44444444-4444-4444-8444-444444444444',
          title: 'Syntetisk artikkel om vektendring',
          evidence_item_count: 1,
          full_text_in_library: true,
          readability_checked: true,
          grounding_machine_proved: false,
        },
      ],
    },
    final_controls: [],
    ...overrides,
  }
}

function port(overrides: Partial<CandidateGateway> = {}): CandidateGateway {
  return {
    listQueue: () =>
      Promise.resolve([
        {
          candidateId: CANDIDATE,
          statement: 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
          subjectDrug: 'sertralin',
          topic: 'vektendring',
          certaintyLevel: 'low',
          sourceCount: 1,
          finalControlCount: 0,
          builtAt: '2026-09-26T09:00:00+00:00',
        },
      ]),
    read: () => Promise.resolve(parseCandidateView(kandidatsvar())),
    recordFinalControl: () => Promise.resolve(),
    ...overrides,
  }
}

describe('Antidep 2-skallet', () => {
  it('viser ærlig resetstatus uten klinisk prototypeinnhold', () => {
    render(
      <MemoryRouter>
        <AppLayout />
      </MemoryRouter>,
    )
    expect(
      screen.getByRole('heading', { name: 'Kunnskapsgrunnlaget bygges på nytt' }),
    ).toBeVisible()
    expect(screen.getByText(/Ingen klinisk veiledning/)).toBeVisible()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })

  it.each(['/review', '/extraction-review', '/evidence/new', '/drugs/sertralin'])(
    'stenger gammel direkteadresse %s',
    (path) => {
      render(
        <MemoryRouter initialEntries={[path]}>
          <AppLayout />
        </MemoryRouter>,
      )
      expect(screen.getByRole('heading', { name: 'Siden finnes ikke' })).toBeVisible()
    },
  )
})

describe('klinikerflaten', () => {
  it('viser køen med nok til å velge, og ikke mer', async () => {
    render(
      <MemoryRouter initialEntries={['/kandidater']}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    expect(
      await screen.findByRole('link', {
        name: 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
      }),
    ).toBeVisible()
    expect(screen.getByText(/Eksperimentelt og upublisert/)).toBeVisible()
  })

  it('viser påstanden, vurderingen, kildedekningen og de ordrette utdragene', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', {
        name: 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
      }),
    ).toBeVisible()
    expect(screen.getByText(/Sikkerhet i grunnlaget \(grade\): lav/)).toBeVisible()
    expect(screen.getByText(/Fullteksten ligger i biblioteket/)).toBeVisible()
    expect(screen.getByText(/Mean percent weight change was 1.0% at endpoint/)).toBeVisible()
    // Sluttkontrollen er bundet til avtrykket, og avtrykket vises.
    expect(screen.getByText(DIGEST)).toBeVisible()
    // En godkjenning publiserer ingenting, og flaten sier det selv.
    expect(screen.getByText(/publiserer ingenting/)).toBeVisible()
  })

  // ANTIDEP_CONSTITUTION.md regel 4: et felt uten kontroll er ikke det samme
  // som et felt uten avvik. Vises bare det andre, ser det første ut som det.
  it('navngir kontrollfeltene ingen kontroll dekker', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/Ikke kontrollerte felter: timepoint/)).toBeVisible()
    expect(screen.getByText(/Maskinbeviset for kildeforankringen gjelder ikke/)).toBeVisible()
  })

  it('sender avtrykket flaten faktisk viste, uendret, med sluttkontrollen', async () => {
    const recordFinalControl = vi.fn(() => Promise.resolve())
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port({ recordFinalControl })} />
      </MemoryRouter>,
    )

    await screen.findByRole('button', { name: 'Registrer sluttkontroll' })
    fireEvent.change(screen.getByLabelText('Begrunnelse'), {
      target: { value: 'Lest i klinikerens egen visning; innholdet holder mål.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer sluttkontroll' }))

    await waitFor(() => {
      expect(recordFinalControl).toHaveBeenCalledWith({
        candidateId: CANDIDATE,
        seenCandidateDigest: DIGEST,
        decision: 'approved',
        rationale: 'Lest i klinikerens egen visning; innholdet holder mål.',
      })
    })
  })

  // En kandidat hvis grunnlag er endret, er ikke den kandidaten noen leste.
  it('stenger sluttkontrollen når grunnlaget er endret siden forseglingen', async () => {
    const view = parseCandidateView(
      kandidatsvar({ is_current: false, current_digest: `sha256:${'c'.repeat(64)}` }),
    )
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port({ read: () => Promise.resolve(view) })} />
      </MemoryRouter>,
    )

    expect(await screen.findByText(/er endret siden den ble bygget/)).toBeVisible()
    expect(
      screen.queryByRole('button', { name: 'Registrer sluttkontroll' }),
    ).not.toBeInTheDocument()
  })

  it('viser en avvisning fra databasen ordrett framfor en tom side', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout
          gateway={port({
            read: () => Promise.reject(new Error('Kandidatinnhold er tilgangsbegrenset.')),
          })}
        />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/tilgangsbegrenset/)).toBeVisible()
  })
})
