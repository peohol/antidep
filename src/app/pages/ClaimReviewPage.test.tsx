// ============================================================================
// Kontrolløkten for én påstandsrevisjon
//
// Testene beskriver hele den menneskelige kjeden i én flyt: påstanden, kilden,
// feltene, de sju kontrollpunktene, publiseringsbeslutningen og publiseringen.
// Og de beskriver grensene som ikke er myket opp: fire beslutningsobjekter,
// ingen «godkjenn alt», og et utfall som utledes framfor å velges.
// ============================================================================

import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_EXTRACTION_IDS,
  TEST_REVIEW_IDS,
  TEST_USER_IDS,
  claimReviewPayload,
  extractionReviewPayload,
  renderRoute,
  type FakeApi,
} from '../test-support'

const PATH = `/review/${TEST_REVIEW_IDS.revision}`

/** Feltene fiksturens evidensfunn krever kontrollert, i gatens egen rekkefølge. */
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

const CHECKPOINTS = [
  'Kildestøtte',
  'Populasjon',
  'Komparator',
  'Tidsrom',
  'Retning og størrelse',
  'Forbehold',
  'Motstridende evidens',
]

const GATE_OPEN = { status: 'passes' } as const

function renderClaimControl(
  revisionOverrides: Record<string, unknown> = {},
  reviewerActorId?: string,
  api: FakeApi = {},
) {
  return renderRoute(PATH, {
    api: {
      claim_review_workspace: {
        data:
          reviewerActorId === undefined
            ? claimReviewPayload(revisionOverrides)
            : claimReviewPayload(revisionOverrides, reviewerActorId),
      },
      ...api,
    },
    auth: { initialUserId: TEST_USER_IDS.a },
  })
}

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

/**
 * Overskriften på det åpne steget.
 *
 * Leses av overskriften og ikke av teksten i steget: tolkningen inne i steget
 * begynner med det samme feltnavnet («Behandlingsarmen er virkestoff a»), og et
 * tekstsøk ville truffet begge.
 */
function openStepTitle(): string {
  return openStep().querySelector('.control-step__title')?.textContent ?? ''
}

async function answerYesThrough(titles: readonly string[]): Promise<void> {
  for (const title of titles) {
    await waitFor(() => {
      expect(openStepTitle()).toContain(title)
    })
    clickAnswer('Ja')
  }
}

async function startControl(): Promise<void> {
  fireEvent.click(await screen.findByRole('button', { name: 'Start kontroll' }))
}

/** Går gjennom kildetilgangen og alle feltene, og lagrer ekstraksjonskontrollen. */
async function completeExtractionPart(): Promise<void> {
  await startControl()
  await waitFor(() => {
    expect(openStepTitle()).toContain('Hvilken tilgang har du til kilden?')
  })
  clickAnswer('Ja')
  // Tittelen bærer et kildeprefiks når økten dekker flere kildegrunnlag.
  await answerYesThrough(REQUIRED_FIELDS)
  fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
}

/** Svarer «Ja» på lenken og på alle sju kontrollpunktene. */
async function completeClaimPart(): Promise<void> {
  await answerYesThrough(['Grunnlagets rolle', ...CHECKPOINTS])
}

describe('Kontrolløkten — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute(PATH)
    expect(await screen.findByText('Du må logge inn for å vurdere en påstand.')).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Kontrolløkten — innledningen', () => {
  it('viser påstanden som skal kontrolleres, og ingenting mer', async () => {
    renderClaimControl()
    // Ordlyden står også i de tekniske detaljene; her spørres det om
    // innledningssteget, der den er selve spørsmålet.
    await screen.findByRole('button', { name: 'Start kontroll' })
    expect(document.querySelector('.control-claim-statement')?.textContent).toBe(
      'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
    )
    // Kildekontrollen begynner ikke før økten er startet.
    expect(screen.queryByText('Har du tilgang til fullteksten?')).not.toBeInTheDocument()
  })

  it('henter både påstanden og ekstraksjonsgrunnlaget bak hver lenke', async () => {
    const { rpcCalls } = renderClaimControl()
    await screen.findByRole('button', { name: 'Start kontroll' })
    expect(rpcCalls).toEqual([
      {
        name: 'claim_review_workspace',
        args: { p_claim_revision_id: TEST_REVIEW_IDS.revision },
      },
      {
        name: 'extraction_review_workspace',
        args: { p_evidence_item_id: TEST_REVIEW_IDS.evidenceItem },
      },
    ])
  })
})

describe('Kontrolløkten — kildegrunnlaget', () => {
  it('spør om relasjonen mellom funnet og påstanden i naturlig språk', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await waitFor(() => {
      expect(openStepTitle()).toContain('Grunnlagets rolle')
    })
    expect(
      within(openStep()).getByText('Antidep har registrert at dette funnet støtter påstanden.'),
    ).toBeInTheDocument()
  })

  it('går videre til kildetilgangen når kontrollen startes', async () => {
    renderClaimControl()
    await startControl()
    expect(
      await within(openStep()).findByText('Har du tilgang til fullteksten?'),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Åpne kilden' })).toHaveAttribute(
      'href',
      'https://eksempel.invalid/testkilde-a',
    )
  })

  it('hopper over feltkontrollen når ekstraksjonen allerede er fullt kontrollert', async () => {
    renderClaimControl({}, undefined, {
      extraction_review_workspace: {
        data: extractionReviewPayload({
          covered_check_fields: (extractionReviewPayload()['item'] as Record<string, unknown>)[
            'required_check_fields'
          ],
        }),
      },
    })
    await startControl()
    await within(openStep()).findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const heading = await screen.findByRole('button', {
      name: /Ekstraksjonen er allerede kontrollert/,
    })
    fireEvent.click(heading)
    expect(
      await screen.findByText(
        'Alle feltene dette funnet påstår noe om, er kontrollert mot kilden fra før.',
      ),
    ).toBeInTheDocument()
  })
})

describe('Kontrolløkten — de sju kontrollpunktene', () => {
  it('stiller dem ett om gangen, med bare det grunnlaget punktet handler om', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await answerYesThrough(['Grunnlagets rolle'])
    await waitFor(() => {
      expect(openStepTitle()).toContain('Kildestøtte')
    })
    const step = within(openStep())
    expect(
      step.getByText('Støtter det registrerte grunnlaget faktisk ordlyden i påstanden?'),
    ).toBeInTheDocument()
    expect(step.getByText('Påstanden')).toBeInTheDocument()
    expect(step.getByText('Grunnlaget')).toBeInTheDocument()
    // Neste punkt er ikke framme.
    expect(
      screen.queryByText('Svarer populasjonen påstanden gjelder for til den grunnlaget dekker?'),
    ).not.toBeInTheDocument()
  })

  it('viser alle sju i tur og orden, med spørsmålet hvert av dem svarer på', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await answerYesThrough(['Grunnlagets rolle'])
    for (const checkpoint of CHECKPOINTS) {
      await waitFor(() => {
        expect(openStepTitle()).toContain(checkpoint)
      })
      // Spørsmålet punktet svarer på står i steget, ikke bare etiketten.
      expect(within(openStep()).getByText(/\?$/)).toBeInTheDocument()
      clickAnswer('Ja')
    }
  })

  it('registrerer kontrollen med de sju punktene, lenkene og et utledet utfall', async () => {
    const { rpcCalls } = renderClaimControl()
    await completeExtractionPart()
    await completeClaimPart()
    expect(await screen.findByText('Dette blir registrert som: Bekreftet.')).toBeInTheDocument()
    // Ingen utfallsmeny og ingen retrospektiv fritekst.
    expect(screen.queryByLabelText('Samlet utfall')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Faglig begrunnelse')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Lagre og fortsett' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_human_claim_verification')).toBe(true)
    })
    const args = rpcCalls.find((call) => call.name === 'register_human_claim_verification')
      ?.args as Record<string, unknown>
    expect(args['p_outcome']).toBe('verified')
    expect(args['p_source_support']).toBe('ok')
    expect(args['p_contradictory_evidence_represented']).toBe('ok')
    expect(args['p_seen_evidence_set_digest']).toBe(`sha256-v1:${'d'.repeat(64)}`)
    expect(args['p_findings']).toBeNull()
    const citations = args['p_citations'] as Record<string, unknown>[]
    expect(citations).toHaveLength(1)
    expect(citations[0]?.['relationship_supported']).toBe('ok')
    // Kildetilgangen er den kontrolløren allerede oppga for den kilden.
    expect(citations[0]?.['source_access']).toBe('original_source')
    expect(citations[0]?.['source_version_id']).toBe(TEST_EXTRACTION_IDS.sourceVersion)
  })

  it('utleder «må rettes» av et avvik på ett kontrollpunkt', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await answerYesThrough(['Grunnlagets rolle'])
    await waitFor(() => {
      expect(openStepTitle()).toContain('Kildestøtte')
    })
    clickAnswer('Nei')
    fireEvent.change(screen.getByLabelText('Hva er feil, eller hvordan bør dette forstås?'), {
      target: { value: 'Grunnlaget måler noe annet enn ordlyden sier.' },
    })
    await answerYesThrough(CHECKPOINTS.slice(1))
    expect(await screen.findByText('Dette blir registrert som: Må rettes.')).toBeInTheDocument()
  })
})

describe('Kontrolløkten — publiseringsbeslutningen', () => {
  it('oppsummerer kontrollen, og spør så om påstanden kan publiseres', async () => {
    renderClaimControl({ approval_readiness: GATE_OPEN })
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))

    expect(
      await screen.findByText(/21 av 21 nødvendige delkontroller er bekreftet\./),
    ).toBeInTheDocument()
    expect(screen.getByText(/Ingen åpne avvik\./)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Godkjenn for publisering' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Be om endringer' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Avvis' })).toBeInTheDocument()
  })

  it('krever ingen fritekst for en godkjenning, og skriver begrunnelsen selv', async () => {
    const { rpcCalls } = renderClaimControl({ approval_readiness: GATE_OPEN })
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Godkjenn for publisering' }))
    expect(
      screen.queryByLabelText('Hva må endres, eller hvorfor holder ikke påstanden?'),
    ).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Lagre beslutningen' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_publication_approval')).toBe(true)
    })
    const args = rpcCalls.find((call) => call.name === 'register_publication_approval')
      ?.args as Record<string, unknown>
    expect(args['p_decision']).toBe('approved')
    expect(args['p_rationale']).toContain('Godkjent for publisering etter en fullført kontrolløkt')
  })

  it('krever en konkret begrunnelse for «Be om endringer»', async () => {
    renderClaimControl({ approval_readiness: GATE_OPEN })
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Be om endringer' }))
    const note = await screen.findByLabelText('Hva må endres, eller hvorfor holder ikke påstanden?')
    expect(screen.getByRole('button', { name: 'Lagre beslutningen' })).toBeDisabled()
    fireEvent.change(note, { target: { value: 'Forbeholdet om kort oppfølging mangler.' } })
    expect(screen.getByRole('button', { name: 'Lagre beslutningen' })).toBeEnabled()
  })

  // Godkjenningen kan ikke gis før grunnlaget er kontrollert. Vilkåret leses av
  // den samme funksjonen skriveveien bruker, ikke regnet ut på nytt her.
  it('tilbyr ikke godkjenning når databasen sier at forutsetningene ikke er oppfylt', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    expect(
      await screen.findByText(
        'Du kan ikke gå god for publisering ennå: grunnlaget er ikke ferdig kontrollert.',
      ),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole('button', { name: 'Godkjenn for publisering' }),
    ).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Avvis' })).toBeInTheDocument()
  })
})

describe('Kontrolløkten — publiseringen', () => {
  it('er en egen handling, og tilbys bare når publiseringsgaten passerer', async () => {
    const { rpcCalls } = renderClaimControl({
      approval_readiness: GATE_OPEN,
      publication_gate: GATE_OPEN,
    })
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Godkjenn for publisering' }))
    fireEvent.click(screen.getByRole('button', { name: 'Lagre beslutningen' }))

    fireEvent.click(await screen.findByRole('button', { name: 'Publiser påstanden' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'publish_claim_revision')).toBe(true)
    })
    const args = rpcCalls.find((call) => call.name === 'publish_claim_revision')?.args as Record<
      string,
      unknown
    >
    expect(args['p_claim_revision_id']).toBe(TEST_REVIEW_IDS.revision)
    expect(args['p_reason']).toContain('Publisert etter fullført kontroll')
  })

  it('viser gatens egen blokkering framfor en publiseringsknapp', async () => {
    renderClaimControl()
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    // Vent til flyten har gått videre til beslutningen; et manuelt åpnet steg
    // slipper taket når økten selv går videre.
    await waitFor(() => {
      expect(openStepTitle()).toContain('Kan denne påstanden publiseres slik den står?')
    })
    // Steget finnes, men det inneholder gatens egen begrunnelse og ingen knapp.
    fireEvent.click(screen.getByRole('button', { name: /^Publiser påstanden/ }))
    expect(await screen.findByText('Påstanden kan ikke publiseres ennå.')).toBeInTheDocument()
    expect(
      within(openStep()).queryByRole('button', { name: 'Publiser påstanden' }),
    ).not.toBeInTheDocument()
    // Gatens egen setning står i steget, med den samme ordlyden databasen ga.
    // Den står også i de tekniske detaljene, så spørringen navngir steget.
    expect(
      within(openStep()).getByText('Revisjon har ingen registrert claim-verifikasjon.'),
    ).toBeInTheDocument()
  })

  it('viser databasens egen avvisning når kalleren mangler publisher-rollen', async () => {
    renderClaimControl({ approval_readiness: GATE_OPEN, publication_gate: GATE_OPEN }, undefined, {
      publish_claim_revision: {
        error: 'Kalleren har ikke publisher-rollen som kreves for å publisere.',
      },
    })
    await completeExtractionPart()
    await completeClaimPart()
    fireEvent.click(await screen.findByRole('button', { name: 'Lagre og fortsett' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Godkjenn for publisering' }))
    fireEvent.click(screen.getByRole('button', { name: 'Lagre beslutningen' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Publiser påstanden' }))
    expect(
      await screen.findByText(/Kalleren har ikke publisher-rollen som kreves for å publisere\./),
    ).toBeInTheDocument()
  })
})

describe('Kontrolløkten — grensene', () => {
  it('sier at man ikke kan kontrollere sin egen påstand', async () => {
    renderClaimControl({}, TEST_REVIEW_IDS.synthesisActor)
    await startControl()
    const heading = await screen.findByRole('button', {
      name: /Du kan ikke kontrollere din egen påstand/,
    })
    fireEvent.click(heading)
    expect(
      await screen.findByText(
        'Du formulerte denne revisjonen selv, og kan derfor verken kontrollere eller godkjenne den.',
      ),
    ).toBeInTheDocument()
  })

  it('legger hele dossieret bak «Tekniske detaljer»', async () => {
    renderClaimControl()
    const summaries = await screen.findAllByText('Tekniske detaljer')
    expect(summaries.length).toBeGreaterThan(0)
    const details = summaries[0]?.closest('details')
    expect(details).not.toBeNull()
    expect(
      within(details as HTMLElement).getByText('Publiseringen er blokkert.'),
    ).toBeInTheDocument()
  })
})
