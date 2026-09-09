// ============================================================================
// Kontrolløkten for ett evidensfunn
//
// Testene beskriver arbeidsmodellen, ikke bare markupen: ett spørsmål om
// gangen, kilden ved siden av tolkningen, ingen samlet utfallsmeny, og et
// utfall som utledes av delsvarene.
// ============================================================================

import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_EXTRACTION_IDS,
  TEST_FIELD_GROUNDINGS,
  TEST_USER_IDS,
  extractionReviewPayload,
  fieldGrounding,
  renderRoute,
  type FakeApi,
} from '../test-support'

const PATH = `/extraction-review/${TEST_EXTRACTION_IDS.evidenceItem}`

/** Feltene fiksturen krever kontrollert, i den rekkefølgen gaten oppgir dem. */
const REQUIRED_FIELDS = [
  'Den rå ekstraksjonen, ordrett',
  'Hvor i kilden funnet står',
  'Behandlingsarmen',
  'Endepunktet',
  'Retningen kilden rapporterer',
  'Begrunnelsen for felter uten verdi',
  'Effektmålet',
  'Sammenligningsarmen',
  'Populasjonen funnet gjelder',
  'Antall deltakere',
  'Tidspunktet målingen gjelder',
  'Selve estimatet',
  'Konfidensintervallet',
]

function renderExtractionControl(
  itemOverrides: Record<string, unknown> = {},
  reviewerActorId?: string,
  api: FakeApi = {},
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

/** Steget som står åpent. Den eneste med et synlig svaralternativ. */
function openStep(): HTMLElement {
  const region = document.querySelector('.control-step[data-state="active"]')
  if (region === null) {
    throw new Error('Ingen steg står åpent.')
  }
  return region as HTMLElement
}

function clickAnswer(label: string): void {
  fireEvent.click(within(openStep()).getByRole('button', { name: label }))
}

/** Svarer «Ja» på kildetilgangen og på hvert feltsteg. */
async function answerEverythingYes(): Promise<void> {
  await screen.findByText('Har du tilgang til fullteksten?')
  clickAnswer('Ja')
  for (const field of REQUIRED_FIELDS) {
    await within(openStep()).findByText(field)
    clickAnswer('Ja')
  }
}

describe('Kontrolløkten — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute(PATH)
    expect(
      await screen.findByText('Du må logge inn for å kontrollere et evidensfunn.'),
    ).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Kontrolløkten — grunnlaget', () => {
  it('henter grunnlaget for nøyaktig det funnet adressen peker på', async () => {
    const { rpcCalls } = renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    expect(rpcCalls).toEqual([
      {
        name: 'extraction_review_workspace',
        args: { p_evidence_item_id: TEST_EXTRACTION_IDS.evidenceItem },
      },
    ])
  })

  it('teller delkontrollene, og starter på den første', async () => {
    renderExtractionControl()
    expect(await screen.findByText('Delkontroll: 1 av 13')).toBeInTheDocument()
  })
})

describe('Kontrolløkten — kildetilgangen', () => {
  it('gir en trykkbar lenke til kilden, ikke bare adressen som tekst', async () => {
    renderExtractionControl()
    const link = await screen.findByRole('link', { name: 'Åpne kilden' })
    expect(link).toHaveAttribute('href', 'https://eksempel.invalid/testkilde-a')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
  })

  it('spør først om fullteksten, og om hva man ellers har bare når svaret er nei', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    expect(screen.queryByText('Hva har du da tilgang til?')).not.toBeInTheDocument()
    clickAnswer('Nei')
    expect(await screen.findByText('Hva har du da tilgang til?')).toBeInTheDocument()
    expect(
      screen.getByRole('button', { name: 'Den lagrede kopien Antidep kan etterprøve' }),
    ).toBeInTheDocument()
  })

  it('sier på forhånd at et sammendrag alene ikke kan bære en bekreftelse', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Nei')
    clickAnswer('Bare et sammendrag fra et annet ledd')
    expect(
      await screen.findByText('Med bare et sammendrag kan kontrollen ikke ende i en bekreftelse.'),
    ).toBeInTheDocument()
  })

  // En kildeversjon uten fingeravtrykk er et sporet besøk, ikke en etterprøvbar
  // representasjon (§74.32). Da skal valget ikke tilbys.
  it('tilbyr ikke den lagrede kopien når kildeversjonen mangler fingeravtrykk', async () => {
    renderExtractionControl({
      source_version: {
        source_version_id: TEST_EXTRACTION_IDS.sourceVersion,
        retrieved_at: '2026-09-01T09:00:00Z',
        retrieved_from: 'https://eksempel.invalid/testkilde-a',
        external_version: null,
        content_hash: null,
        has_storage_reference: false,
      },
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Nei')
    await screen.findByText('Hva har du da tilgang til?')
    expect(
      screen.queryByRole('button', { name: 'Den lagrede kopien Antidep kan etterprøve' }),
    ).not.toBeInTheDocument()
  })
})

describe('Kontrolløkten — feltkontrollen', () => {
  it('viser bare det aktive steget, ett felt om gangen', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    // Første felt er åpent …
    expect(await screen.findByText('Testutdrag for raw_extraction.')).toBeInTheDocument()
    // … og det neste er ikke.
    expect(screen.queryByText('Testutdrag for source_locator.')).not.toBeInTheDocument()
  })

  it('viser kildeutdraget, pekeren og Antideps tolkning side om side', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(await step.findByText('Kilden')).toBeInTheDocument()
    expect(step.getByText('Antideps tolkning')).toBeInTheDocument()
    expect(step.getByText('Testutdrag for raw_extraction.')).toBeInTheDocument()
    expect(step.getByText('Testkilde A, avsnittet om raw_extraction')).toBeInTheDocument()
    expect(step.getByText('Stemmer Antideps tolkning med kilden?')).toBeInTheDocument()
  })

  it('legger agentens begrunnelse bak «Hvorfor mener Antidep dette?»', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(await step.findByText('Hvorfor mener Antidep dette?')).toBeInTheDocument()
    expect(
      step.getByText('Testbegrunnelse for hvordan utdraget ble til verdien for raw_extraction.'),
    ).toBeInTheDocument()
  })

  it('formulerer tolkningen som et utsagn, uten databasefeltnavn', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    // Fram til antall deltakere.
    for (const field of REQUIRED_FIELDS.slice(0, 9)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    const step = within(openStep())
    expect(await step.findByText('Studien inkluderte 240 deltakere.')).toBeInTheDocument()
    expect(screen.queryByText('sample_size_availability')).not.toBeInTheDocument()
  })

  it('lukker det besvarte steget, markerer det, og åpner det neste', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Den rå ekstraksjonen, ordrett')
    clickAnswer('Ja')
    expect(await screen.findByText('Stemmer')).toBeInTheDocument()
    expect(await within(openStep()).findByText('Hvor i kilden funnet står')).toBeInTheDocument()
  })

  it('lar et tidligere steg åpnes igjen', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Den rå ekstraksjonen, ordrett')
    fireEvent.click(screen.getByRole('button', { name: /Hvilken tilgang har du til kilden\?/ }))
    expect(await screen.findByText('Har du tilgang til fullteksten?')).toBeInTheDocument()
  })

  it('åpner avviksfeltet på det steget avviket ble oppdaget, og lar steget stå åpent til det er beskrevet', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Den rå ekstraksjonen, ordrett')
    expect(
      screen.queryByLabelText('Hva er feil, eller hvordan bør dette tolkes?'),
    ).not.toBeInTheDocument()
    clickAnswer('Nei')
    const note = await screen.findByLabelText('Hva er feil, eller hvordan bør dette tolkes?')
    expect(note).toBeInTheDocument()
    // Steget står åpent til avviket er beskrevet: teksten hører til nettopp
    // denne delkontrollen, mens kilden er framme.
    expect(within(openStep()).getByText('Den rå ekstraksjonen, ordrett')).toBeInTheDocument()
    fireEvent.change(note, { target: { value: 'Sitatet står ikke i kilden.' } })
    expect(await within(openStep()).findByText('Hvor i kilden funnet står')).toBeInTheDocument()
  })

  // Gamle funn har ingen forankring, og fraværet skal stå som fravær: Antidep
  // gjetter aldri et utdrag ut av `raw_extraction`.
  it('sier tydelig fra når et felt ikke er forankret', async () => {
    renderExtractionControl({
      field_groundings: TEST_FIELD_GROUNDINGS.filter(
        (grounding) => grounding['check_field'] !== 'raw_extraction',
      ),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(
      await step.findByText(
        'Ekstraksjonen har ikke registrert hvilket kildeutdrag denne tolkningen bygger på.',
      ),
    ).toBeInTheDocument()
    expect(step.queryByText('Hvorfor mener Antidep dette?')).not.toBeInTheDocument()
  })

  it('viser ingen forankring i det hele tatt for et funn registrert før forankringen fantes', async () => {
    renderExtractionControl({ field_groundings: [] })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    expect(
      await within(openStep()).findByText(
        'Ekstraksjonen har ikke registrert hvilket kildeutdrag denne tolkningen bygger på.',
      ),
    ).toBeInTheDocument()
  })
})

describe('Kontrolløkten — utfallet utledes', () => {
  it('har verken utfallsmeny, metodefelt eller et samlet funnfelt', async () => {
    renderExtractionControl()
    await answerEverythingYes()
    await screen.findByText('Dette blir registrert som: Bekreftet.')
    expect(screen.queryByLabelText('Samlet utfall')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Hvordan gjennomførte du kontrollen?')).not.toBeInTheDocument()
    expect(
      screen.queryByLabelText('Funn (påkrevd når utfallet ikke er «Bekreftet»)'),
    ).not.toBeInTheDocument()
  })

  it('registrerer en bekreftelse med feltene, begrunnelsen og uten funn', async () => {
    const { rpcCalls } = renderExtractionControl()
    await answerEverythingYes()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))

    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_human_extraction_verification')).toBe(
        true,
      )
    })
    const call = rpcCalls.find(
      (candidate) => candidate.name === 'register_human_extraction_verification',
    )
    const args = call?.args as Record<string, unknown>
    expect(args['p_outcome']).toBe('verified')
    expect(args['p_source_access']).toBe('original_source')
    expect(args['p_findings']).toBeNull()
    expect(args['p_seen_extraction_digest']).toBe(TEST_EXTRACTION_IDS.digest)
    expect((args['p_checked_fields'] as string[]).length).toBe(13)
    expect(args['p_rationale']).toContain('13 av 13 delkontroller besvart')
  })

  it('utleder «må rettes» av et avvik, og tar avviksteksten med i funnet', async () => {
    const { rpcCalls } = renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Den rå ekstraksjonen, ordrett')
    clickAnswer('Nei')
    fireEvent.change(screen.getByLabelText('Hva er feil, eller hvordan bør dette tolkes?'), {
      target: { value: 'Sitatet står ikke i kilden.' },
    })
    for (const field of REQUIRED_FIELDS.slice(1)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    expect(await screen.findByText('Dette blir registrert som: Må rettes.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Lagre og fortsett' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_human_extraction_verification')).toBe(
        true,
      )
    })
    const args = rpcCalls.find(
      (candidate) => candidate.name === 'register_human_extraction_verification',
    )?.args as Record<string, unknown>
    expect(args['p_outcome']).toBe('needs_correction')
    expect(args['p_findings']).toContain('Sitatet står ikke i kilden.')
  })

  it('kan ikke lagres før alle delkontrollene er besvart', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    fireEvent.click(screen.getByRole('button', { name: /Lagre kontrollen av kildegrunnlaget/ }))
    expect(await screen.findByRole('button', { name: 'Lagre og fortsett' })).toBeDisabled()
  })
})

describe('Kontrolløkten — grensene', () => {
  it('sier at man ikke kan kontrollere sin egen ekstraksjon', async () => {
    renderExtractionControl({}, TEST_EXTRACTION_IDS.extractorActor)
    // Overskriften står synlig som det første i økten; begrunnelsen er ett
    // klikk unna.
    const heading = await screen.findByRole('button', {
      name: /Du kan ikke kontrollere din egen ekstraksjon/,
    })
    fireEvent.click(heading)
    expect(
      await screen.findByText(
        'Du registrerte denne ekstraksjonen selv, og kan derfor ikke kontrollere den.',
      ),
    ).toBeInTheDocument()
  })

  it('viser databasens egen avvisning ordrett', async () => {
    renderExtractionControl({}, undefined, {
      register_human_extraction_verification: {
        error: 'Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram.',
      },
    })
    await answerEverythingYes()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    expect(
      await screen.findByText(
        /Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram\./,
      ),
    ).toBeInTheDocument()
  })

  // Endres grunnlaget under arbeidet, skal bare det som faktisk er endret gjøres
  // om igjen. Her er ett felts forankring byttet ut mens økten pågikk.
  it('nullstiller bare de delkontrollene grunnlaget faktisk er endret på', async () => {
    const changed = TEST_FIELD_GROUNDINGS.map((grounding) =>
      grounding['check_field'] === 'estimate'
        ? fieldGrounding('estimate', { source_excerpt: 'Et helt annet utdrag.' })
        : grounding,
    )
    renderExtractionControl({}, undefined, {
      extraction_review_workspace: [
        { data: extractionReviewPayload() },
        { data: extractionReviewPayload({ field_groundings: changed }) },
      ],
      register_human_extraction_verification: {
        error: 'Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram.',
      },
    })
    await answerEverythingYes()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    expect(
      await screen.findByText(/1 av delkontrollene dine gjelder ikke lenger\./),
    ).toBeInTheDocument()
    // Og det er nettopp estimatsteget som står åpent igjen.
    expect(await within(openStep()).findByText('Selve estimatet')).toBeInTheDocument()
  })
})

describe('Kontrolløkten — tekniske detaljer', () => {
  it('legger hele dossieret bak én egen flate, utenfor arbeidsflyten', async () => {
    renderExtractionControl()
    expect(await screen.findByText('Tekniske detaljer')).toBeInTheDocument()
    // Feltdekningen er teknisk og hører ikke til noen enkelt beslutning.
    const details = screen.getByText('Tekniske detaljer').closest('details')
    expect(details).not.toBeNull()
    expect(within(details as HTMLElement).getByText('Feltdekning')).toBeInTheDocument()
  })
})
