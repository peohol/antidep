import '@testing-library/jest-dom/vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it, vi } from 'vitest'
import { AppLayout } from './App'
import type { AgentWorkGateway } from './agent-work-gateway'
import type { CandidateGateway } from './candidate-gateway'
import type { PublicationGateway } from './publication-gateway'
import { parseAgentWorkQueue } from '../agents/agent-task'
import { parseCandidateView } from '../lib/candidate-view'
import { parsePublicationOutcome } from '../lib/published-claim'
import {
  candidateContent,
  candidateResponse,
  publicationHistoryEvent,
  publicationOutcomeResponse,
  publishedClaimResponse,
  publishedIndexEntry,
  FIXTURE_CANDIDATE_DIGEST,
  FIXTURE_CANDIDATE_ID,
  FIXTURE_CLAIM_ID,
  FIXTURE_STATEMENT,
} from '../lib/candidate-test-support'
import { parsePublishedClaim, parsePublishedClaimIndex } from '../lib/published-claim'

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
    publish: () => Promise.resolve(parsePublicationOutcome(publicationOutcomeResponse())),
    ...overrides,
  }
}

/** Den publiserte flatens vei til databasen, som en dobbel. */
function publicationPort(overrides: Partial<PublicationGateway> = {}): PublicationGateway {
  return {
    listPublished: () => Promise.resolve(parsePublishedClaimIndex([publishedIndexEntry()])),
    readPublished: () => Promise.resolve(parsePublishedClaim(publishedClaimResponse())),
    publish: () => Promise.resolve(parsePublicationOutcome(publicationOutcomeResponse())),
    withdraw: () =>
      Promise.resolve(
        parsePublicationOutcome(
          publicationOutcomeResponse({ action: 'withdraw', published: false }),
        ),
      ),
    rollback: () =>
      Promise.resolve(parsePublicationOutcome(publicationOutcomeResponse({ action: 'rollback' }))),
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

describe('publiseringen', () => {
  it('er en egen handling etter sluttkontrollen, og sender avtrykket uendret', async () => {
    const publish = vi.fn(() =>
      Promise.resolve(parsePublicationOutcome(publicationOutcomeResponse())),
    )
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout gateway={port({ publish })} />
      </MemoryRouter>,
    )

    await screen.findByRole('button', { name: 'Publiser kandidaten' })
    // To handlinger, to knapper: å godkjenne og å publisere er ikke det samme.
    expect(screen.getByRole('button', { name: 'Registrer sluttkontroll' })).toBeVisible()

    fireEvent.change(screen.getByLabelText('Begrunnelse for publiseringen'), {
      target: { value: 'Godkjent innhold tas i bruk.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Publiser kandidaten' }))

    await waitFor(() => {
      expect(publish).toHaveBeenCalledWith({
        candidateId: CANDIDATE,
        seenCandidateDigest: DIGEST,
        reason: 'Godkjent innhold tas i bruk.',
      })
    })
  })

  it('viser databasens avvisning ordrett når mandatet mangler', async () => {
    render(
      <MemoryRouter initialEntries={[`/kandidater/${CANDIDATE}`]}>
        <AppLayout
          gateway={port({
            publish: () =>
              Promise.reject(
                new Error('Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.'),
              ),
          })}
        />
      </MemoryRouter>,
    )

    await screen.findByRole('button', { name: 'Publiser kandidaten' })
    fireEvent.change(screen.getByLabelText('Begrunnelse for publiseringen'), {
      target: { value: 'Forsøk uten mandat.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Publiser kandidaten' }))

    expect(await screen.findByText(/ikke gyldig publisher-rolle/)).toBeVisible()
  })
})

describe('den publiserte klinikerflaten', () => {
  it('lister det som faktisk er publisert', async () => {
    render(
      <MemoryRouter initialEntries={['/publisert']}>
        <AppLayout publication={publicationPort()} />
      </MemoryRouter>,
    )

    expect(await screen.findByRole('link', { name: FIXTURE_STATEMENT })).toBeVisible()
    expect(screen.getByText(/Sikkerhet i grunnlaget: lav/)).toBeVisible()
  })

  it('viser det forseglede innholdet med proveniens og historikk', async () => {
    render(
      <MemoryRouter initialEntries={[`/publisert/${FIXTURE_CLAIM_ID}`]}>
        <AppLayout publication={publicationPort()} />
      </MemoryRouter>,
    )

    expect(await screen.findByRole('heading', { name: FIXTURE_STATEMENT })).toBeVisible()
    // Proveniensen står over innholdet, ikke bare i historikken under.
    expect(screen.getAllByText(/Sluttkontrollert av Navngitt fagperson/).length).toBeGreaterThan(0)
    // Avtrykket vises, slik at innholdet er etterprøvbart mot det som ble godkjent.
    expect(screen.getByText(DIGEST)).toBeVisible()
    expect(
      within(section('Publiseringshistorikk')).getByText(/publisert — Navngitt publisher/),
    ).toBeVisible()
    // Den samme rendereren som kandidatsiden bruker: samme visning, ett innhold.
    expect(
      within(section('Evidensvurdering')).getByText(/Sikkerhet i grunnlaget \(grade\): lav/),
    ).toBeVisible()
  })

  it('slutter å presentere et tilbaketrukket innhold som gjeldende, men beholder historikken', async () => {
    const withdrawn = parsePublishedClaim({
      claim_id: FIXTURE_CLAIM_ID,
      published: false,
      withdrawn: true,
      content: null,
      history: [
        publicationHistoryEvent({
          action: 'withdraw',
          final_control: null,
          reason: 'Nye data gjør formuleringen misvisende.',
        }),
        publicationHistoryEvent({ publication_event_id: '99999999-9999-4999-8999-999999999999' }),
      ],
    })
    render(
      <MemoryRouter initialEntries={[`/publisert/${FIXTURE_CLAIM_ID}`]}>
        <AppLayout
          publication={publicationPort({ readPublished: () => Promise.resolve(withdrawn) })}
        />
      </MemoryRouter>,
    )

    expect(
      await screen.findByRole('heading', { name: /Ingenting er publisert om denne påstanden nå/ }),
    ).toBeVisible()
    expect(
      screen.getByText(/trukket tilbake, og presenteres ikke lenger som gjeldende/),
    ).toBeVisible()
    // Innholdet er borte som gjeldende, men historikken er fortsatt etterprøvbar.
    expect(screen.queryByRole('region', { name: 'Evidensvurdering' })).not.toBeInTheDocument()
    const historikk = within(section('Publiseringshistorikk'))
    expect(historikk.getByText(/Nye data gjør formuleringen misvisende/)).toBeVisible()
  })

  it('lar en rollback peke på en tidligere publisert versjon, med dens eget avtrykk', async () => {
    const rollback = vi.fn(() =>
      Promise.resolve(parsePublicationOutcome(publicationOutcomeResponse({ action: 'rollback' }))),
    )
    const eldre = publicationHistoryEvent({
      publication_event_id: '99999999-9999-4999-8999-999999999999',
      candidate_id: '88888888-8888-4888-8888-888888888888',
      candidate_digest: `sha256:${'c'.repeat(64)}`,
      revision_number: 1,
    })
    const view = parsePublishedClaim(
      publishedClaimResponse({ history: [publicationHistoryEvent(), eldre] }),
    )
    render(
      <MemoryRouter initialEntries={[`/publisert/${FIXTURE_CLAIM_ID}`]}>
        <AppLayout
          publication={publicationPort({ readPublished: () => Promise.resolve(view), rollback })}
        />
      </MemoryRouter>,
    )

    await screen.findByRole('button', { name: 'Rull tilbake' })
    fireEvent.change(screen.getByLabelText('Gå tilbake til'), {
      target: { value: '88888888-8888-4888-8888-888888888888' },
    })
    fireEvent.change(screen.getByLabelText('Begrunnelse for rollback'), {
      target: { value: 'Den nyere formuleringen var feil.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Rull tilbake' }))

    await waitFor(() => {
      expect(rollback).toHaveBeenCalledWith({
        claimId: FIXTURE_CLAIM_ID,
        targetCandidateId: '88888888-8888-4888-8888-888888888888',
        seenCandidateDigest: `sha256:${'c'.repeat(64)}`,
        reason: 'Den nyere formuleringen var feil.',
      })
    })
  })

  it('krever en begrunnelse for tilbaketrekkingen', async () => {
    const withdraw = vi.fn(() =>
      Promise.resolve(
        parsePublicationOutcome(
          publicationOutcomeResponse({ action: 'withdraw', published: false }),
        ),
      ),
    )
    render(
      <MemoryRouter initialEntries={[`/publisert/${FIXTURE_CLAIM_ID}`]}>
        <AppLayout publication={publicationPort({ withdraw })} />
      </MemoryRouter>,
    )

    const knapp = await screen.findByRole('button', { name: 'Trekk tilbake' })
    expect(knapp).toBeDisabled()

    fireEvent.change(screen.getByLabelText('Begrunnelse for tilbaketrekking'), {
      target: { value: 'Nye data gjør formuleringen misvisende.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Trekk tilbake' }))

    await waitFor(() => {
      expect(withdraw).toHaveBeenCalledWith({
        claimId: FIXTURE_CLAIM_ID,
        reason: 'Nye data gjør formuleringen misvisende.',
      })
    })
  })

  // Agentarbeidet er en egen flate med et eget mandat, og forsiden skal peke
  // dit: uten lenken finnes siden bare for den som kjenner adressen.
  it('viser agentarbeidet på sin egen adresse, og lenker dit fra forsiden', async () => {
    const agentWork: AgentWorkGateway = {
      listQueue: () => Promise.resolve(parseAgentWorkQueue([])),
      assignRoleModel: () => Promise.reject(new Error('ingen oppgave')),
      readTask: () => Promise.reject(new Error('ingen oppgave')),
      importAnswer: () => Promise.reject(new Error('ingen oppgave')),
      listRunners: () => Promise.resolve([]),
      registerRunner: () => Promise.reject(new Error('ingen oppgave')),
      issuePairingCode: () => Promise.reject(new Error('ingen oppgave')),
      revokeRunner: () => Promise.reject(new Error('ingen oppgave')),
    }

    render(
      <MemoryRouter initialEntries={['/']}>
        <AppLayout />
      </MemoryRouter>,
    )
    expect(screen.getByRole('link', { name: 'Agentarbeid' })).toHaveAttribute(
      'href',
      '/agentarbeid',
    )

    cleanup()
    render(
      <MemoryRouter initialEntries={['/agentarbeid']}>
        <AppLayout agentWork={agentWork} />
      </MemoryRouter>,
    )
    expect(
      await screen.findByRole('heading', { level: 1, name: 'Oppgaver til KI-agentene' }),
    ).toBeInTheDocument()
    expect(await screen.findByText('Ingen agentoppgaver venter nå.')).toBeInTheDocument()
  })
})
