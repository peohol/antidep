import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'
import { AppLayout } from './App'
import type { CandidateGateway } from './candidate-gateway'
import { parseCandidateView } from '../lib/candidate-view'
import {
  candidateContent,
  candidateResponse,
  FIXTURE_CANDIDATE_DIGEST,
  FIXTURE_CANDIDATE_ID,
  FIXTURE_STATEMENT,
} from '../lib/candidate-test-support'

const DIGEST = FIXTURE_CANDIDATE_DIGEST
const CANDIDATE = FIXTURE_CANDIDATE_ID

/**
 * Ett avsnitt på kandidatsiden, slått opp på overskriften sin.
 *
 * Oppslagene går gjennom avsnittet og ikke gjennom hele siden, fordi siden
 * *også* viser hele det forseglede innholdet ordrett: et treff der ville vært
 * et treff i avtrykket, ikke i den lesbare visningen prøven gjelder.
 */
function section(name: string): HTMLElement {
  return screen.getByRole('region', { name })
}

/**
 * Hver bladverdi i det forseglede innholdet, som den står i svaret.
 *
 * Brukes til å prøve at flaten faktisk viser alt avtrykket dekker. Prøven er
 * skrevet mot innholdet og ikke mot en liste over felter, slik at et nytt felt
 * i `knowledge.candidate_content` gjør prøven rød framfor å bli usynlig.
 */
function leaves(value: unknown): readonly string[] {
  if (Array.isArray(value)) {
    return value.flatMap(leaves)
  }
  if (typeof value === 'object' && value !== null) {
    return Object.values(value).flatMap(leaves)
  }
  if (value === null) {
    return []
  }
  return [String(value)]
}

function port(overrides: Partial<CandidateGateway> = {}): CandidateGateway {
  return {
    listQueue: () =>
      Promise.resolve([
        {
          candidateId: CANDIDATE,
          statement: FIXTURE_STATEMENT,
          subjectDrug: 'sertralin',
          topic: 'vektendring',
          certaintyLevel: 'low',
          sourceCount: 1,
          finalControlCount: 0,
          builtAt: '2026-09-26T09:00:00+00:00',
        },
      ]),
    read: () => Promise.resolve(parseCandidateView(candidateResponse())),
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
    expect(await screen.findByRole('link', { name: FIXTURE_STATEMENT })).toBeVisible()
    expect(screen.getByText(/Eksperimentelt og upublisert/)).toBeVisible()
  })

  it('viser påstanden, vurderingen, kildedekningen og de ordrette utdragene', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )

    expect(await screen.findByRole('heading', { name: FIXTURE_STATEMENT })).toBeVisible()
    expect(
      within(section('Evidensvurdering')).getByText(/Sikkerhet i grunnlaget \(grade\): lav/),
    ).toBeVisible()
    expect(
      within(section('Kildedekning')).getByText(/Fullteksten ligger i biblioteket/),
    ).toBeVisible()
    expect(
      within(section('Evidensgrunnlaget')).getByText(
        /Mean percent weight change was 1.0% at endpoint/,
      ),
    ).toBeVisible()
    // Sluttkontrollen er bundet til avtrykket, og avtrykket vises.
    expect(screen.getByText(DIGEST)).toBeVisible()
    // En godkjenning publiserer ingenting, og flaten sier det selv.
    expect(screen.getByText(/publiserer ingenting/)).toBeVisible()
  })

  // Avtrykket dekker vurderingen i sin helhet. Vises bare sikkerhetsgraden,
  // attesterer fagpersonen en nedgradering hen aldri ble vist grunnen til.
  it('viser hvert GRADE-domene for seg', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    await screen.findByRole('heading', { name: FIXTURE_STATEMENT })
    const vurdering = within(section('Evidensvurdering'))
    expect(vurdering.getByText(/Risiko for systematisk skjevhet: alvorlig/)).toBeVisible()
    expect(vurdering.getByText(/Upresishet: svært alvorlig/)).toBeVisible()
    // Et domene som ikke lot seg vurdere, er ikke et domene uten problem.
    expect(vurdering.getByText(/Inkonsistens: lot seg ikke vurdere/)).toBeVisible()
    expect(vurdering.getByText(/Ingen dose-respons-sammenheng kunne vurderes/)).toBeVisible()
  })

  it('viser hvert av de sju kontrollpunktene i kildestøttekontrollen', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    await screen.findByRole('heading', { name: FIXTURE_STATEMENT })
    const kontroll = within(section('Kildestøttekontroll'))
    expect(kontroll.getByText(/Utfall: må rettes/)).toBeVisible()
    expect(kontroll.getByText(/Kildestøtte: holder/)).toBeVisible()
    expect(kontroll.getByText(/Forbehold komplett: avvik/)).toBeVisible()
    // not_assessable er ikke ok, og skal ikke leses som det.
    expect(kontroll.getByText(/Komparator: lot seg ikke bedømme/)).toBeVisible()
    expect(kontroll.getByText(/Forbeholdet om langtidsbruk mangler/)).toBeVisible()
  })

  it('sier når ingen kildestøttekontroll er registrert, framfor å utelate den', async () => {
    const view = parseCandidateView(
      candidateResponse({ content: candidateContent({ citation_support_check: null }) }),
    )
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port({ read: () => Promise.resolve(view) })} />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/Ingen kildestøttekontroll er registrert/)).toBeVisible()
  })

  it('viser tallene evidensfunnet faktisk bærer', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    await screen.findByRole('heading', { name: FIXTURE_STATEMENT })
    const evidens = within(section('Evidensgrunnlaget'))
    expect(evidens.getByText(/Antall deltakere: 220/)).toBeVisible()
    expect(evidens.getByText(/Konfidensintervall \(95 %\): 0.4 til 1.6/)).toBeVisible()
    expect(evidens.getByText(/Åpen oppfølging etter uke 24/)).toBeVisible()
  })

  // Sluttkontrollen binder fagpersonen til avtrykket, og avtrykket dekker hele
  // innholdet. En visning som bare viste et utvalg, ville latt hen attestere
  // opplysninger hen aldri så — og avstanden ville vokst for hvert nye felt i
  // `knowledge.candidate_content`. Prøven leser innholdet selv, ikke en liste.
  it('viser alt avtrykket dekker, før beslutningen avgis', async () => {
    const svar = candidateResponse()
    const { container } = render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port()} />
      </MemoryRouter>,
    )
    await screen.findByRole('button', { name: 'Registrer sluttkontroll' })

    const shown = container.textContent ?? ''
    const missing = leaves(svar['content']).filter((leaf) => !shown.includes(leaf))
    expect(missing).toEqual([])
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
      candidateResponse({ is_current: false, current_digest: `sha256:${'c'.repeat(64)}` }),
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
