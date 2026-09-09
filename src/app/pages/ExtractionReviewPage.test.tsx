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
  TEST_SEMANTIC_FIELDS,
  TEST_USER_IDS,
  extractionReviewPayload,
  fieldGrounding,
  renderRoute,
  reviewSource,
  type FakeApi,
} from '../test-support'

const PATH = `/extraction-review/${TEST_EXTRACTION_IDS.evidenceItem}`

/**
 * Feltene kontrolløren faktisk får spørsmål om, i den rekkefølgen
 * `workflow.semantic_check_fields` gir dem.
 *
 * `raw_extraction` og `source_locator` står ikke her, og skal ikke gjøre det:
 * de er provenansfelter uten klinisk innhold, og garantien de bar ligger nå i
 * hver enkelt forankring.
 */
const SEMANTIC_FIELDS = [
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
  for (const field of SEMANTIC_FIELDS) {
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
    expect(await screen.findByText('Delkontroll: 1 av 11')).toBeInTheDocument()
  })
})

describe('Kontrolløkten — kildetilgangen', () => {
  it('lenker til artikkelen via DOI, ikke til maskinens henteadresse', async () => {
    renderExtractionControl()
    const link = await screen.findByRole('link', { name: 'Åpne kilden' })
    expect(link).toHaveAttribute('href', 'https://doi.org/10.1000/testkilde-a.1')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
  })

  // Henteadressen er maskinens eksakte adresse — for et EUtils-kall er den XML
  // — og hører hjemme i proveniensen, ikke i den kliniske flyten.
  it('viser henteadressen bare under «Tekniske detaljer»', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    const address = screen.getByText(/eutils\.eksempel\.invalid/)
    expect(address.closest('details')).not.toBeNull()
    expect(
      within(address.closest('details') as HTMLElement).getByText('Tekniske detaljer'),
    ).toBeInTheDocument()
    // Og ingen steg i selve flyten nevner den.
    expect(
      document.querySelector('.control-step')?.textContent?.includes('eutils.eksempel.invalid'),
    ).toBe(false)
  })

  it('faller tilbake til PubMed-siden når kilden ikke har DOI', async () => {
    renderExtractionControl({
      source: reviewSource({
        identifiers: [{ identifier_system: 'pmid', identifier_value: '10999999' }],
      }),
    })
    const link = await screen.findByRole('link', { name: 'Åpne kilden' })
    expect(link).toHaveAttribute('href', 'https://pubmed.ncbi.nlm.nih.gov/10999999/')
  })

  it('sier fra framfor å lenke til noe annet når kilden mangler begge', async () => {
    renderExtractionControl({
      source: reviewSource({ identifiers: [] }),
    })
    expect(
      await screen.findByText(
        'Kilden har ingen registrert DOI eller PubMed-ID, så Antidep kan ikke lage en lenke til artikkelen.',
      ),
    ).toBeInTheDocument()
  })

  it('sier hva slags representasjon ekstraksjonen bygger på', async () => {
    renderExtractionControl()
    expect(
      await screen.findByText('Ekstraksjonen bygger på fullteksten av kilden.'),
    ).toBeInTheDocument()
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
        representation: 'abstract',
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
    expect(await screen.findByText('Testutdrag for intervention_arm.')).toBeInTheDocument()
    // … og det neste er ikke.
    expect(screen.queryByText('Testutdrag for outcome.')).not.toBeInTheDocument()
  })

  it('viser den ordrette teksten, pekeren og Antideps tolkning side om side', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(await step.findByText('Ordrett tekst')).toBeInTheDocument()
    expect(step.getByText('Antideps tolkning')).toBeInTheDocument()
    // Venstresiden er nøyaktig agentens registrerte utdrag, ordrett.
    expect(step.getByText('Testutdrag for intervention_arm.')).toBeInTheDocument()
    expect(step.getByText('Testkilde A, avsnittet om intervention_arm')).toBeInTheDocument()
    // Høyresiden er den strukturerte verdien, som en setning.
    expect(step.getByText('Behandlingsarmen er virkestoff a.')).toBeInTheDocument()
    expect(step.getByText('Stemmer Antideps tolkning med teksten?')).toBeInTheDocument()
  })

  // Skuffen skal inneholde det som trengs for ett svar, og ingenting mer.
  it('gjentar verken lenken eller adressen i feltskuffen', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    await step.findByText('Ordrett tekst')
    expect(step.queryByRole('link', { name: 'Åpne kilden' })).not.toBeInTheDocument()
    expect(step.queryByText(/eutils\.eksempel\.invalid/)).not.toBeInTheDocument()
    expect(step.queryByText(/doi\.org/)).not.toBeInTheDocument()
  })

  // De to provenansfeltene er ikke kliniske påstander, og skal ikke stjele et
  // steg fra kontrolløren.
  it('stiller ingen spørsmål om den rå ekstraksjonen eller den globale pekeren', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    for (const field of SEMANTIC_FIELDS) {
      const title = within(openStep()).getByText(field, { selector: '.control-step__title' })
      expect(title).toBeInTheDocument()
      clickAnswer('Ja')
    }
    expect(
      screen.queryByText('Den rå ekstraksjonen, ordrett', { selector: '.control-step__title' }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByText('Hvor i kilden funnet står', { selector: '.control-step__title' }),
    ).not.toBeInTheDocument()
  })

  it('legger agentens begrunnelse bak «Hvorfor mener Antidep dette?»', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(await step.findByText('Hvorfor mener Antidep dette?')).toBeInTheDocument()
    expect(
      step.getByText('Testbegrunnelse for hvordan utdraget ble til verdien for intervention_arm.'),
    ).toBeInTheDocument()
  })

  it('formulerer tolkningen som et utsagn, uten databasefeltnavn', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    // Fram til antall deltakere.
    for (const field of SEMANTIC_FIELDS.slice(0, 7)) {
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
    await within(openStep()).findByText('Behandlingsarmen')
    clickAnswer('Ja')
    expect(await screen.findByText('Stemmer')).toBeInTheDocument()
    expect(await within(openStep()).findByText('Endepunktet')).toBeInTheDocument()
  })

  it('lar et tidligere steg åpnes igjen', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Behandlingsarmen')
    fireEvent.click(screen.getByRole('button', { name: /Hvilken tilgang har du til kilden\?/ }))
    expect(await screen.findByText('Har du tilgang til fullteksten?')).toBeInTheDocument()
  })

  it('åpner avviksfeltet på det steget avviket ble oppdaget, og lar steget stå åpent til det er beskrevet', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Behandlingsarmen')
    expect(
      screen.queryByLabelText('Hva er feil, eller hvordan bør dette tolkes?'),
    ).not.toBeInTheDocument()
    clickAnswer('Nei')
    const note = await screen.findByLabelText('Hva er feil, eller hvordan bør dette tolkes?')
    expect(note).toBeInTheDocument()
    // Steget står åpent til avviket er beskrevet: teksten hører til nettopp
    // denne delkontrollen, mens kilden er framme.
    expect(within(openStep()).getByText('Behandlingsarmen')).toBeInTheDocument()
    fireEvent.change(note, { target: { value: 'Utdraget navngir et annet virkestoff.' } })
    expect(await within(openStep()).findByText('Endepunktet')).toBeInTheDocument()
  })

  // Et hull i forankringen stopper økten. Alternativet — å be kontrolløren lete
  // fram utdraget selv — er nøyaktig arbeidsformen forankringen finnes for å
  // fjerne.
  it('stopper økten og ber om ny ekstraksjon når ett felt mangler forankring', async () => {
    renderExtractionControl({
      field_groundings: TEST_FIELD_GROUNDINGS.filter(
        (grounding) => grounding['check_field'] !== 'estimate',
      ),
      grounded_check_fields: TEST_SEMANTIC_FIELDS.filter((field) => field !== 'estimate'),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(
      await step.findByText(
        'Ekstraksjonen mangler kildeforankring for 1 av feltene den påstår noe om, og kan derfor ikke kontrolleres felt for felt.',
      ),
    ).toBeInTheDocument()
    expect(step.getByText('Uten forankring: Selve estimatet.')).toBeInTheDocument()
    // Og ingen feltskuff er tilbudt.
    expect(
      screen.queryByText('Behandlingsarmen', { selector: '.control-step__title' }),
    ).not.toBeInTheDocument()
  })

  it('behandler et funn fra før forankringen fantes som ukontrollerbart', async () => {
    renderExtractionControl({ field_groundings: [], grounded_check_fields: [] })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    expect(
      await within(openStep()).findByText(
        'Ekstraksjonen mangler kildeforankring for 11 av feltene den påstår noe om, og kan derfor ikke kontrolleres felt for felt.',
      ),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/Funnet må ekstraheres på nytt etter gjeldende protokoll/),
    ).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Lagre og fortsett' })).not.toBeInTheDocument()
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
    // Gaten krever de tretten feltene dekket; de elleve kontrolløren svarte på
    // pluss de to provenansfeltene en bekreftelse fører opp.
    expect([...(args['p_checked_fields'] as string[])].sort()).toContain('raw_extraction')
    expect([...(args['p_checked_fields'] as string[])].sort()).toContain('source_locator')
    expect((args['p_checked_fields'] as string[]).length).toBe(13)
    expect(args['p_rationale']).toContain('11 av 11 delkontroller besvart')
  })

  it('utleder «må rettes» av et avvik, og tar avviksteksten med i funnet', async () => {
    const { rpcCalls } = renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Behandlingsarmen')
    clickAnswer('Nei')
    fireEvent.change(screen.getByLabelText('Hva er feil, eller hvordan bør dette tolkes?'), {
      target: { value: 'Utdraget navngir et annet virkestoff.' },
    })
    for (const field of SEMANTIC_FIELDS.slice(1)) {
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
    expect(args['p_findings']).toContain('Utdraget navngir et annet virkestoff.')
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
