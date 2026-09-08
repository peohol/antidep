import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_EXTRACTION_IDS,
  TEST_USER_IDS,
  extractionReviewPayload,
  extractionVerificationRecord,
  renderRoute,
} from '../test-support'

const PATH = `/extraction-review/${TEST_EXTRACTION_IDS.evidenceItem}`

/**
 * Panelet under én overskrift.
 *
 * Flere av tekstene finnes med vilje flere steder — feltnavnene står både i
 * feltdekningen og i avhukingslisten — så testene sier hvilket panel de spør i
 * framfor å be om at teksten er unik.
 */
async function panel(heading: string): Promise<HTMLElement> {
  const found = (await screen.findByRole('heading', { name: heading })).closest('section')
  if (found === null) {
    throw new Error(`Fant ingen seksjon rundt overskriften «${heading}».`)
  }
  return found
}

function renderExtractionReview(
  itemOverrides: Record<string, unknown> = {},
  reviewerActorId?: string,
  api: Record<string, unknown> = {},
) {
  return renderRoute(PATH, {
    api: {
      extraction_review_workspace: {
        data:
          reviewerActorId === undefined
            ? extractionReviewPayload(itemOverrides)
            : extractionReviewPayload(itemOverrides, reviewerActorId),
      },
      ...api,
    },
    auth: { initialUserId: TEST_USER_IDS.a },
  })
}

describe('Kildekontroll — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute(PATH)
    expect(
      await screen.findByText('Du må logge inn for å kontrollere et evidensfunn.'),
    ).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Kildekontroll — grunnlaget', () => {
  it('henter grunnlaget for nøyaktig det funnet adressen peker på', async () => {
    const { rpcCalls } = renderExtractionReview()
    await screen.findByRole('heading', { name: 'Kilden kontrollen skal skje mot' })
    expect(rpcCalls).toEqual([
      {
        name: 'extraction_review_workspace',
        args: { p_evidence_item_id: TEST_EXTRACTION_IDS.evidenceItem },
      },
    ])
  })

  it('viser kilden, statusen, hentestedet og fingeravtrykket', async () => {
    renderExtractionReview()
    const source = within(await panel('Kilden kontrollen skal skje mot'))
    expect(await source.findByText('Testkilde A: vektendring ved åtte uker')).toBeInTheDocument()
    expect(source.getByText('I bruk')).toBeInTheDocument()
    expect(source.getByText('https://eksempel.invalid/testkilde-a')).toBeInTheDocument()
    expect(source.getByText(`sha256:${'a'.repeat(64)}`)).toBeInTheDocument()
    expect(source.getByText('Tabell 2, side 114')).toBeInTheDocument()
  })

  // En kilde som er trukket tilbake, skal stå med ord og ikke bare med en farge:
  // publiseringsgatens G7 stopper på nettopp den statusen.
  it('viser en tilbaketrukket kilde som det den er', async () => {
    renderExtractionReview({
      source: {
        source_id: '88888888-8888-4888-8888-111111111111',
        source_type: 'journal_article',
        title: 'Testkilde A: vektendring ved åtte uker',
        authors_or_issuer: 'Testforfatter m.fl.',
        publisher_or_journal: null,
        publication_date: null,
        publication_date_precision: null,
        source_status: 'retracted',
        status_note: 'Trukket tilbake av tidsskriftet.',
      },
    })
    const source = within(await panel('Kilden kontrollen skal skje mot'))
    expect(
      await source.findByText('Trukket tilbake av tidsskrift eller utgiver'),
    ).toBeInTheDocument()
    expect(source.getByText('Trukket tilbake av tidsskriftet.')).toBeInTheDocument()
  })

  it('viser hele den strukturerte ekstraksjonen, med grunn for feltene uten verdi', async () => {
    renderExtractionReview()
    const fields = within(await panel('Ekstraksjonen, felt for felt'))
    expect(await fields.findByText('Randomisert kontrollert studie')).toBeInTheDocument()
    expect(fields.getByText('vektendring')).toBeInTheDocument()
    expect(fields.getByText('1.7 kg')).toBeInTheDocument()
    expect(fields.getByText('0.9 til 2.5 (95 %)')).toBeInTheDocument()
    // Forbeholdene er ikke registrert på dette funnet, og fravær står som fravær.
    expect(fields.getByText('Ingen forbehold er registrert')).toBeInTheDocument()
  })

  it('viser den rå ekstraksjonen når den finnes', async () => {
    renderExtractionReview({
      extraction: {
        ...((extractionReviewPayload()['item'] as Record<string, unknown>)['extraction'] as Record<
          string,
          unknown
        >),
        raw_extraction: { sitat: 'Mean weight change was 1.7 kg.' },
      },
    })
    const raw = within(await panel('Rå ekstraksjon'))
    expect(await raw.findByText('Mean weight change was 1.7 kg.')).toBeInTheDocument()
  })

  // «Ingen rå ekstraksjon» er ikke det samme som «kilden sier ingenting».
  it('sier eksplisitt når ingen rå ekstraksjon er lagret', async () => {
    renderExtractionReview()
    const raw = within(await panel('Rå ekstraksjon'))
    expect(
      await raw.findByText(/Ingen rå ekstraksjon er lagret på dette funnet/),
    ).toBeInTheDocument()
  })
})

/**
 * Listen under ett felt i en definisjonsliste.
 *
 * De tre listene i feltdekningen inneholder de samme etikettene med vilje — et
 * felt kan stå både i kravet og i det som gjenstår — så testen spør under
 * hvilken overskrift den ser, framfor å telle treff på hele panelet.
 */
function itemsUnder(section: HTMLElement, label: string): string[] {
  const term = within(section).getByText(label)
  const value = term.parentElement?.querySelector('dd')
  if (value === null || value === undefined) {
    throw new Error(`Fant ingen verdi under «${label}».`)
  }
  return Array.from(value.querySelectorAll('li')).map((entry) => entry.textContent ?? '')
}

describe('Kildekontroll — feltdekningen', () => {
  it('viser hva som kreves, hva som teller, og hva som står igjen', async () => {
    renderExtractionReview({
      required_check_fields: ['source_locator', 'outcome', 'estimate'],
      covered_check_fields: ['outcome'],
    })
    const coverage = await panel('Feltdekning')
    expect(itemsUnder(coverage, 'Må være kontrollert')).toEqual([
      'Hvor i kilden funnet står',
      'Endepunktet',
      'Selve estimatet',
    ])
    expect(itemsUnder(coverage, 'Teller som kontrollert nå')).toEqual(['Endepunktet'])
    expect(itemsUnder(coverage, 'Står igjen')).toEqual([
      'Hvor i kilden funnet står',
      'Selve estimatet',
    ])
  })

  it('sier at ingenting teller som kontrollert når dekningen er tom', async () => {
    renderExtractionReview({ covered_check_fields: [] })
    const coverage = within(await panel('Feltdekning'))
    expect(await coverage.findByText('Ingen felter teller som kontrollert')).toBeInTheDocument()
  })

  it('sier at dekningen er komplett når ingenting står igjen', async () => {
    renderExtractionReview({
      required_check_fields: ['source_locator'],
      covered_check_fields: ['source_locator'],
    })
    const coverage = within(await panel('Feltdekning'))
    expect(await coverage.findByText(/Ingenting\. Dekningen er komplett/)).toBeInTheDocument()
  })
})

describe('Kildekontroll — historikken', () => {
  it('sier at ingen kontroll er registrert, uten å la det se ut som et avslag', async () => {
    renderExtractionReview()
    const history = within(await panel('Registrerte kontroller av denne ekstraksjonen'))
    expect(await history.findByText(/Ingen kontroll er registrert ennå/)).toBeInTheDocument()
  })

  it('viser en registrert kontroll med utfall, felter, begrunnelse og funn', async () => {
    renderExtractionReview({
      current_extraction_verification_id: TEST_EXTRACTION_IDS.verification,
      extraction_verifications: [extractionVerificationRecord()],
    })
    const history = within(await panel('Registrerte kontroller av denne ekstraksjonen'))
    expect(
      await history.findByRole('heading', { name: /Uavklart — Ekstraksjonsverifikator/ }),
    ).toBeInTheDocument()
    expect(history.getByText(/Maskinell kontroll/)).toBeInTheDocument()
    expect(history.getByText('Hvor i kilden funnet står')).toBeInTheDocument()
    expect(
      history.getByText('Funn: Fant ikke utdraget som dekker tidspunktet.'),
    ).toBeInTheDocument()
    expect(history.getByText(/\(gjeldende\)/)).toBeInTheDocument()
  })

  it('skiller en menneskelig kontroll fra en maskinell', async () => {
    renderExtractionReview({
      extraction_verifications: [
        extractionVerificationRecord({
          verifier_actor_type: 'human',
          verifier_actor_key: 'human:testreviewer',
          verifier_display_name: 'Test Reviewer',
          agent_run_id: null,
        }),
      ],
    })
    const history = within(await panel('Registrerte kontroller av denne ekstraksjonen'))
    expect(await history.findByText(/Menneskelig kontroll/)).toBeInTheDocument()
  })
})

describe('Kildekontroll — skjemaet', () => {
  // Ingen forhåndsutfylling som kan leses som en vurdering: avkrysningene starter
  // tomme, kildetilgangen på den svakeste verdien og utfallet på det mest
  // forbeholdne (ANTIDEP_CONSTITUTION.md §6).
  it('har ingen felter huket av på forhånd', async () => {
    renderExtractionReview()
    await screen.findByRole('heading', { name: 'Registrer din kontroll av ekstraksjonen' })
    const boxes = screen.getAllByRole('checkbox')
    expect(boxes.length).toBeGreaterThan(0)
    expect(boxes.every((box) => !(box as HTMLInputElement).checked)).toBe(true)
  })

  it('starter på den svakeste kildetilgangen og det mest forbeholdne utfallet', async () => {
    renderExtractionReview()
    const access = await screen.findByLabelText('Hva hadde du tilgang til?')
    expect((access as HTMLSelectElement).value).toBe('derived_summary')
    const outcome = screen.getByLabelText('Samlet utfall')
    expect((outcome as HTMLSelectElement).value).toBe('uncertain')
  })

  // Uten en kildeversjon med fingeravtrykk finnes det ingen etterprøvbar
  // representasjon å kontrollere mot, og valget skal ikke tilbys.
  it('sperrer «etterprøvbar representasjon» når kildeversjonen mangler fingeravtrykk', async () => {
    renderExtractionReview({ source_version: null })
    const access = await screen.findByLabelText('Hva hadde du tilgang til?')
    const option = within(access).getByRole('option', { name: 'Etterprøvbar representasjon' })
    expect(option).toBeDisabled()
  })

  it('sender avtrykket og de avhukede feltene uendret til skriveveien', async () => {
    const { rpcCalls } = renderExtractionReview({
      required_check_fields: ['source_locator', 'outcome'],
    })
    await screen.findByRole('heading', { name: 'Registrer din kontroll av ekstraksjonen' })

    fireEvent.click(screen.getByLabelText('Hvor i kilden funnet står'))
    fireEvent.change(screen.getByLabelText('Hva hadde du tilgang til?'), {
      target: { value: 'original_source' },
    })
    fireEvent.change(screen.getByLabelText('Hvordan gjennomførte du kontrollen?'), {
      target: { value: 'Slo opp tabellen i originalartikkelen.' },
    })
    fireEvent.change(screen.getByLabelText('Funn (påkrevd når utfallet ikke er «Bekreftet»)'), {
      target: { value: 'Endepunktet lot seg ikke bekrefte.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kontrollen' }))

    await waitFor(() => {
      expect(rpcCalls).toContainEqual({
        name: 'register_human_extraction_verification',
        args: {
          p_evidence_item_id: TEST_EXTRACTION_IDS.evidenceItem,
          p_seen_extraction_digest: TEST_EXTRACTION_IDS.digest,
          p_outcome: 'uncertain',
          p_source_access: 'original_source',
          p_checked_fields: ['source_locator'],
          p_rationale: 'Slo opp tabellen i originalartikkelen.',
          p_findings: 'Endepunktet lot seg ikke bekrefte.',
        },
      })
    })
  })

  it('viser databasens egen avvisning ordrett når registreringen avvises', async () => {
    renderExtractionReview({}, undefined, {
      register_human_extraction_verification: {
        error: 'Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram.',
      },
    })
    await screen.findByRole('heading', { name: 'Registrer din kontroll av ekstraksjonen' })
    fireEvent.change(screen.getByLabelText('Hvordan gjennomførte du kontrollen?'), {
      target: { value: 'Prøve.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kontrollen' }))
    expect(
      await screen.findByText(
        /Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram\./,
      ),
    ).toBeInTheDocument()
  })

  // Generering og kontroll skal være atskilte operasjoner. Køen utelater egne
  // funn, men et direkte oppslag når dem fortsatt.
  it('tilbyr ikke skjemaet når kalleren selv registrerte ekstraksjonen', async () => {
    renderExtractionReview({}, TEST_EXTRACTION_IDS.extractorActor)
    expect(
      await screen.findByText(
        'Du har selv registrert denne ekstraksjonen, og kan derfor ikke kontrollere den.',
      ),
    ).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Registrer kontrollen' })).toBeNull()
  })
})

describe('Kildekontroll — påstandene funnet bærer', () => {
  it('lenker til reviewflaten for hver påstandsrevisjon funnet er koblet til', async () => {
    renderExtractionReview()
    const linked = within(await panel('Påstander dette funnet er koblet til'))
    const link = await linked.findByRole('link', {
      name: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
    })
    expect(link).toHaveAttribute('href', '/review/33333333-3333-4333-8333-222222222222')
  })

  it('sier eksplisitt at kontrollen trengs også når ingen påstand er koblet til', async () => {
    renderExtractionReview({ linked_claim_revisions: [] })
    const linked = within(await panel('Påstander dette funnet er koblet til'))
    expect(
      await linked.findByText(/Ingen påstandsrevisjon er koblet til dette funnet ennå/),
    ).toBeInTheDocument()
  })
})

describe('Kildekontroll — tekniske feil', () => {
  it('sier at en feil er teknisk og ikke et svar om innholdet', async () => {
    renderRoute(PATH, {
      api: {
        extraction_review_workspace: {
          error: 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
        },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(
      await screen.findByText(
        /Dette er en teknisk feil, ikke et svar om at ekstraksjonen er i orden/,
      ),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet\./),
    ).toBeInTheDocument()
  })
})
