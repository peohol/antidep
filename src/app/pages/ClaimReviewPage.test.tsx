import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import {
  TEST_REVIEW_IDS,
  TEST_USER_IDS,
  claimReviewPayload,
  renderRoute,
  reviewDecisionRecord,
  reviewLink,
  reviewVerificationRecord,
} from '../test-support'

const PATH = `/review/${TEST_REVIEW_IDS.revision}`

/**
 * Panelet under én overskrift.
 *
 * Flere av tekstene finnes med vilje flere steder på flaten — kildetittelen står
 * både i grunnlaget og over feltene som gjelder den lenken, og
 * «Godkjent for publisering» står både i historikken og som et valg i skjemaet.
 * Testene sier derfor hvilket panel de spør i, framfor å be om at teksten er
 * unik.
 */
function panel(heading: string): HTMLElement {
  const found = screen.getByRole('heading', { name: heading }).closest('section')
  if (found === null) {
    throw new Error(`Fant ingen seksjon rundt overskriften «${heading}».`)
  }
  return found
}

function renderReview(revisionOverrides: Record<string, unknown> = {}, reviewerActorId?: string) {
  return renderRoute(PATH, {
    api: {
      claim_review_workspace: {
        data:
          reviewerActorId === undefined
            ? claimReviewPayload(revisionOverrides)
            : claimReviewPayload(revisionOverrides, reviewerActorId),
      },
    },
    auth: { initialUserId: TEST_USER_IDS.a },
  })
}

describe('Reviewarbeidsflaten — ikke innlogget', () => {
  it('viser en henvisning til Min tilgang, og spør ikke databasen', async () => {
    const { rpcCalls } = renderRoute(PATH)
    expect(await screen.findByText('Du må logge inn for å vurdere en påstand.')).toBeInTheDocument()
    expect(rpcCalls).toEqual([])
  })
})

describe('Reviewarbeidsflaten — grunnlaget', () => {
  it('henter grunnlaget for nøyaktig den revisjonen adressen peker på', async () => {
    const { rpcCalls } = renderReview()
    await screen.findByRole('heading', { name: 'Påstanden' })
    expect(rpcCalls).toEqual([
      {
        name: 'claim_review_workspace',
        args: { p_claim_revision_id: TEST_REVIEW_IDS.revision },
      },
    ])
  })

  it('viser påstandens ordlyd og de strukturerte feltene', async () => {
    renderReview()
    expect(
      await screen.findByText(
        'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
      ),
    ).toBeInTheDocument()
    expect(screen.getByText('Voksne, korttidsbehandling ved depresjon')).toBeInTheDocument()
    expect(screen.getByText('Evidensbasert syntese')).toBeInTheDocument()
  })

  it('viser evidenslenken med kilde, lokator, kildeversjon og fingeravtrykk', async () => {
    renderReview()
    await screen.findByRole('heading', { name: 'Påstanden' })
    const evidence = within(panel('Evidensgrunnlaget (1 lenker)'))
    expect(evidence.getByText('Tabell 2, side 114')).toBeInTheDocument()
    expect(evidence.getByText('https://eksempel.invalid/testkilde-a')).toBeInTheDocument()
    expect(evidence.getByText(new RegExp(`sha256:${'a'.repeat(64)}`))).toBeInTheDocument()
  })

  it('viser den gjeldende ekstraksjonsverifikasjonen for hvert funn', async () => {
    renderReview()
    await screen.findByRole('heading', { name: 'Påstanden' })
    expect(
      within(panel('Evidensgrunnlaget (1 lenker)')).getByText(/Bekreftet · Originalkilden/),
    ).toBeInTheDocument()
  })

  it('skiller «ingen registrert ekstraksjonskontroll» fra en negativ kontroll', async () => {
    renderReview({ links: [reviewLink({ current_extraction_verification: null })] })
    expect(await screen.findByText(/Ingen ekstraksjonskontroll er registrert/)).toBeInTheDocument()
  })

  it('viser evidensvurderingen med GRADE-domenene', async () => {
    renderReview()
    await screen.findByRole('heading', { name: 'Påstanden' })
    const assessment = within(panel('Evidensvurdering'))
    expect(assessment.getByText('Lav sikkerhet')).toBeInTheDocument()
    // To domener er «Alvorlig» og to «Lot seg ikke vurdere». Det siste er ikke
    // det samme som «Ikke alvorlig» (ANTIDEP_CONSTITUTION.md §6), og begge
    // gjengis for hvert domene framfor å slås sammen.
    expect(assessment.getAllByText('Alvorlig')).toHaveLength(2)
    expect(assessment.getAllByText('Lot seg ikke vurdere')).toHaveLength(2)
    expect(assessment.getByText('Ikke alvorlig')).toBeInTheDocument()
  })

  it('sier at en tom liste over ulenket evidens ikke betyr at det ikke finnes noen', async () => {
    renderReview()
    expect(
      await screen.findByText(/Kontrollpunktet om urepresentert motstridende evidens/),
    ).toBeInTheDocument()
  })

  it('viser urepresentert registrert evidens når den finnes', async () => {
    renderReview({
      unlinked_related_evidence: [
        {
          evidence_item_id: '66666666-6666-4666-8666-999999999999',
          source_title: 'Ulenket testkilde',
          source_status: 'active',
          intervention_drug_name: 'virkestoff a',
          outcome_label: 'vektendring',
          reported_direction: 'decrease',
          effect_measure: null,
          estimate: null,
          estimate_unit: null,
          created_by_actor_key: 'agent:evidence-extraction',
        },
      ],
    })
    expect(await screen.findByText('Ulenket testkilde')).toBeInTheDocument()
  })
})

describe('Reviewarbeidsflaten — blokkerende mangler', () => {
  it('gjengir publiseringsgatens egen setning, uten å regne den ut på nytt', async () => {
    renderReview()
    expect(await screen.findByText('Publiseringen er blokkert.')).toBeInTheDocument()
    expect(
      screen.getByText('Revisjon har ingen registrert claim-verifikasjon.'),
    ).toBeInTheDocument()
    expect(
      screen.getByText('En separat kontrollfase skal ha forsøkt å falsifisere påstanden.'),
    ).toBeInTheDocument()
  })

  it('sier at gaten stopper på det første kravet, slik at én blokkering ikke leses som den eneste', async () => {
    renderReview()
    expect(
      await screen.findByText(/Gaten stopper på det første kravet som ikke er oppfylt/),
    ).toBeInTheDocument()
  })

  it('viser at gaten passerer når den gjør det, og at publisering er en annen handling', async () => {
    renderReview({ publication_gate: { status: 'passes' } })
    expect(await screen.findByText(/Publiseringsgaten passerer/)).toBeInTheDocument()
    expect(screen.getByText(/utføres av en publisher/)).toBeInTheDocument()
  })
})

describe('Reviewarbeidsflaten — de to beslutningene', () => {
  it('har to atskilte skjemaer og ingen «godkjenn alt»-knapp', async () => {
    renderReview()
    expect(await screen.findByRole('button', { name: 'Registrer kontrollen' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Registrer beslutningen' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /godkjenn alt/i })).toBeNull()
  })

  it('viser alle sju kontrollpunktene med spørsmålet hvert av dem svarer på', async () => {
    renderReview()
    await screen.findByRole('button', { name: 'Registrer kontrollen' })
    for (const label of [
      'Kildestøtte',
      'Populasjon',
      'Komparator',
      'Tidsrom',
      'Retning og størrelse',
      'Forbehold',
      'Motstridende evidens',
    ]) {
      expect(screen.getByLabelText(label)).toBeInTheDocument()
    }
    expect(
      screen.getByText('Finnes det relevant motstridende evidens som ikke er representert?'),
    ).toBeInTheDocument()
  })

  it('starter med det mest forbeholdne valget, slik at et urørt felt ikke hevder noe', async () => {
    renderReview()
    expect(await screen.findByLabelText('Kildestøtte')).toHaveValue('not_assessable')
    expect(screen.getByLabelText('Samlet utfall')).toHaveValue('uncertain')
    expect(screen.getByLabelText('Hva hadde du tilgang til?')).toHaveValue('derived_summary')
  })

  it('sender kontrollen med avtrykket flaten faktisk viste, og med lenkens egen kildeversjon', async () => {
    const { rpcCalls } = renderReview()
    await screen.findByRole('button', { name: 'Registrer kontrollen' })

    fireEvent.change(screen.getByLabelText('Hva hadde du tilgang til?'), {
      target: { value: 'original_source' },
    })
    fireEvent.change(screen.getByLabelText('Holder den registrerte relasjonstypen?'), {
      target: { value: 'ok' },
    })
    for (const label of [
      'Kildestøtte',
      'Populasjon',
      'Komparator',
      'Tidsrom',
      'Retning og størrelse',
      'Forbehold',
      'Motstridende evidens',
    ]) {
      fireEvent.change(screen.getByLabelText(label), { target: { value: 'ok' } })
    }
    fireEvent.change(screen.getByLabelText('Samlet utfall'), { target: { value: 'verified' } })
    fireEvent.change(screen.getAllByLabelText('Faglig begrunnelse')[0] as HTMLElement, {
      target: { value: 'Gikk gjennom ordlyd, forbehold og grunnlaget.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kontrollen' }))

    await screen.findByRole('heading', { name: 'Påstanden' })
    const call = rpcCalls.find((rpc) => rpc.name === 'register_human_claim_verification')
    expect(call?.args).toMatchObject({
      p_claim_revision_id: TEST_REVIEW_IDS.revision,
      p_seen_evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
      p_outcome: 'verified',
      p_source_support: 'ok',
      p_contradictory_evidence_represented: 'ok',
      p_rationale: 'Gikk gjennom ordlyd, forbehold og grunnlaget.',
      p_findings: null,
    })
    expect(call?.args).toMatchObject({
      p_citations: [
        {
          claim_evidence_link_id: TEST_REVIEW_IDS.link,
          source_access: 'original_source',
          source_version_id: TEST_REVIEW_IDS.sourceVersion,
          checked_content_hash: `sha256:${'a'.repeat(64)}`,
          relationship_supported: 'ok',
          finding: null,
        },
      ],
    })
  })

  it('sender ingen kildeversjon når revieweren bare hadde et sammendrag', async () => {
    // Kildetilgangen er kallerens egen opplysning, men fingeravtrykket er
    // kildeversjonens: et sammendrag fra et annet ledd er ikke kildeversjonens
    // registrerte representasjon, og de to kan ikke oppgis samtidig.
    const { rpcCalls } = renderReview()
    await screen.findByRole('button', { name: 'Registrer kontrollen' })
    fireEvent.change(screen.getAllByLabelText('Faglig begrunnelse')[0] as HTMLElement, {
      target: { value: 'Bare sammendrag var tilgjengelig.' },
    })
    fireEvent.change(
      screen.getByLabelText('Hva fant du? (påkrevd når relasjonstypen ikke holder)'),
      {
        target: { value: 'Kunne ikke bedømmes.' },
      },
    )
    fireEvent.change(screen.getByLabelText('Funn (påkrevd når utfallet ikke er «Bekreftet»)'), {
      target: { value: 'Kontrollen kunne ikke konkludere.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kontrollen' }))

    await screen.findByRole('heading', { name: 'Påstanden' })
    const call = rpcCalls.find((rpc) => rpc.name === 'register_human_claim_verification')
    expect(call?.args).toMatchObject({
      p_citations: [
        {
          source_access: 'derived_summary',
          source_version_id: null,
          checked_content_hash: null,
        },
      ],
    })
  })

  it('viser databasens avvisning ordrett når kontrollen ikke kan registreres', async () => {
    const { rpcCalls } = renderRoute(PATH, {
      api: {
        claim_review_workspace: { data: claimReviewPayload() },
        register_human_claim_verification: {
          error: 'Evidensgrunnlaget er endret etter at du hentet det fram.',
        },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    await screen.findByRole('button', { name: 'Registrer kontrollen' })
    fireEvent.change(screen.getAllByLabelText('Faglig begrunnelse')[0] as HTMLElement, {
      target: { value: 'Testbegrunnelse.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer kontrollen' }))

    expect(
      await screen.findByText(/Evidensgrunnlaget er endret etter at du hentet det fram/),
    ).toBeInTheDocument()
    expect(rpcCalls.some((rpc) => rpc.name === 'register_publication_approval')).toBe(false)
  })

  it('sender godkjenningen som en egen beslutning, med sitt eget avtrykk', async () => {
    // Godkjenning tilbys bare når forutsetningene holder (migrasjon 006e).
    const { rpcCalls } = renderReview({ approval_readiness: { status: 'passes' } })
    await screen.findByRole('button', { name: 'Registrer beslutningen' })
    fireEvent.change(screen.getByLabelText('Beslutning'), { target: { value: 'approved' } })
    fireEvent.change(screen.getAllByLabelText('Faglig begrunnelse')[1] as HTMLElement, {
      target: { value: 'Går god for publisering.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer beslutningen' }))

    await screen.findByRole('heading', { name: 'Påstanden' })
    const calls = rpcCalls.filter((rpc) => rpc.name === 'register_publication_approval')
    expect(calls).toHaveLength(1)
    expect(calls[0]?.args).toEqual({
      p_claim_revision_id: TEST_REVIEW_IDS.revision,
      p_seen_evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
      p_decision: 'approved',
      p_rationale: 'Går god for publisering.',
    })
    expect(rpcCalls.some((rpc) => rpc.name === 'register_human_claim_verification')).toBe(false)
  })

  it('starter beslutningen på «endringer bedt om», ikke på godkjent', async () => {
    renderReview()
    expect(await screen.findByLabelText('Beslutning')).toHaveValue('changes_requested')
  })

  it('tilbyr ikke godkjenning før grunnlaget er kontrollert, og sier hvorfor', async () => {
    // Migrasjon 006e: skriveveien avviser en approved-beslutning før
    // publiseringsgatens G1-G10 holder. En flate som lot valget stå, ville
    // tilbudt en handling databasen uansett avviser — og verre: den ville sett
    // ut som om godkjenning av et ukontrollert utkast var et lovlig steg.
    renderReview()
    const decision = await screen.findByLabelText('Beslutning')
    expect(within(decision).queryByRole('option', { name: 'Godkjent for publisering' })).toBeNull()
    expect(within(decision).getByRole('option', { name: 'Endringer bedt om' })).toBeInTheDocument()
    expect(within(decision).getByRole('option', { name: 'Avslått' })).toBeInTheDocument()
    expect(
      screen.getByText(
        'Du kan ikke gå god for publisering ennå: grunnlaget er ikke ferdig kontrollert.',
      ),
    ).toBeInTheDocument()
  })

  it('tilbyr godkjenning når forutsetningene holder', async () => {
    renderReview({ approval_readiness: { status: 'passes' } })
    const decision = await screen.findByLabelText('Beslutning')
    expect(
      within(decision).getByRole('option', { name: 'Godkjent for publisering' }),
    ).toBeInTheDocument()
    expect(
      screen.queryByText(
        'Du kan ikke gå god for publisering ennå: grunnlaget er ikke ferdig kontrollert.',
      ),
    ).toBeNull()
  })

  it('henter grunnlaget på nytt etter en registrering', async () => {
    // Både historikken og publiseringsgatens svar endrer seg av en registrering.
    // En flate som fortsatte å vise det forrige svaret, ville vist en blokkering
    // som ikke lenger gjelder — eller skjult en som nettopp oppstod.
    const { rpcCalls } = renderReview()
    await screen.findByRole('button', { name: 'Registrer beslutningen' })
    fireEvent.change(screen.getAllByLabelText('Faglig begrunnelse')[1] as HTMLElement, {
      target: { value: 'Testbegrunnelse.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Registrer beslutningen' }))

    await waitFor(() => {
      expect(rpcCalls.filter((rpc) => rpc.name === 'claim_review_workspace')).toHaveLength(2)
    })
  })
})

describe('Reviewarbeidsflaten — historikken', () => {
  it('viser den deterministiske kontrollen med alle sju punktene og kontrollradene', async () => {
    renderReview({
      current_claim_verification_id: '11111111-1111-4111-8111-333333333333',
      claim_verifications: [reviewVerificationRecord()],
    })
    await screen.findByRole('heading', { name: 'Påstanden' })
    const scoped = within(panel('Registrerte kontroller mot grunnlaget'))
    expect(scoped.getByText(/Uavklart — Claim-verifikator/)).toBeInTheDocument()
    expect(scoped.getByText('(gjeldende)')).toBeInTheDocument()
    // Alle sju punktene vises, også de like: et punkt som ikke vises, er et
    // punkt leseren ikke kan se at ble bedømt.
    expect(scoped.getAllByText('Lot seg ikke bedømme')).toHaveLength(3)
    expect(scoped.getAllByText('Holder')).toHaveLength(4)
    expect(
      scoped.getByText(/Relasjonstypen lot seg ikke bedømme deterministisk/),
    ).toBeInTheDocument()
  })

  it('viser en registrert godkjenning med begrunnelsen sin', async () => {
    renderReview({
      current_review_decision_id: '11111111-1111-4111-8111-555555555555',
      review_decisions: [reviewDecisionRecord()],
    })
    await screen.findByRole('heading', { name: 'Påstanden' })
    const decisions = within(panel('Registrerte publiseringsbeslutninger'))
    expect(decisions.getByText('Godkjent for publisering')).toBeInTheDocument()
    expect(
      decisions.getByText('Går god for at påstanden kan publiseres på dette grunnlaget.'),
    ).toBeInTheDocument()
  })
})

describe('Reviewarbeidsflaten — egen påstand', () => {
  it('viser grunnlaget, men ingen skjemaer, når revieweren selv formulerte revisjonen', async () => {
    renderReview({}, TEST_REVIEW_IDS.synthesisActor)
    expect(await screen.findByText(/Du har selv formulert denne revisjonen/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Registrer kontrollen' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Registrer beslutningen' })).toBeNull()
    expect(screen.getByRole('heading', { name: 'Påstanden' })).toBeInTheDocument()
  })
})

describe('Reviewarbeidsflaten — avvisninger', () => {
  it('viser en teknisk feil som en feil, aldri som en publiseringsblokkering', async () => {
    // Databasen konverterer bare publiseringsgatens egen avvisning til en
    // blokkering (migrasjon 005p); alt annet feller hele kallet. Flaten må da si
    // at dette er en teknisk feil og ikke et svar om innholdet — ellers ville en
    // regresjon i gaten sett ut som en faglig mangel.
    renderRoute(PATH, {
      api: {
        claim_review_workspace: { error: 'internal error i publiseringsgaten' },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Dette er en teknisk feil, ikke et svar om at påstanden ikke kan publiseres',
    )
    expect(screen.queryByText('Publiseringen er blokkert.')).toBeNull()
  })

  it('viser databasens avvisning som en feil, aldri som et tomt grunnlag', async () => {
    renderRoute(PATH, {
      api: {
        claim_review_workspace: {
          error: 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
        },
      },
      auth: { initialUserId: TEST_USER_IDS.a },
    })
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
    )
    expect(screen.queryByRole('heading', { name: 'Påstanden' })).toBeNull()
  })
})
