// ============================================================================
// Kontrolløkten for ett evidensfunn
//
// Testene beskriver arbeidsmodellen, ikke bare markupen: ett spørsmål om
// gangen, kilden ved siden av tolkningen, ingen samlet utfallsmeny, og et
// utfall som utledes av delsvarene.
// ============================================================================

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

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
  reviewExtraction,
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
  'Hvordan resultatet er uttrykt',
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

describe('Kontrolløkten — innledningen', () => {
  // Den første reelle kildekontrollen begynte på spørsmål én uten at noe hadde
  // sagt hvilket virkestoff, hvilket endepunkt eller hvilken artikkel saken
  // gjaldt (PRODUCT_INFORMATION_ARCHITECTURE.md §63.1).
  it('sier hva som skal kontrolleres, før første delkontroll', async () => {
    renderExtractionControl()
    expect(await screen.findByText('Hva skal kontrolleres?')).toBeInTheDocument()
    expect(
      screen.getByText(
        'Du skal nå kontrollere Antideps vurdering av hva kilden sier om vektendring ved bruk av virkestoff a hos voksne med depresjon.',
      ),
    ).toBeInTheDocument()
  })

  it('gjør hele kildetittelen til lenken kontrolløren skal åpne', async () => {
    renderExtractionControl()
    expect(await screen.findByText('Kilden som er brukt')).toBeInTheDocument()
    const link = screen.getByRole('link', { name: 'Testkilde A: vektendring ved åtte uker' })
    expect(link).toHaveAttribute('href', 'https://doi.org/10.1000/testkilde-a.1')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
  })

  // Ingen lenke å bygge er en opplysning, men kilden skal fortsatt navngis — og
  // forklaringen skal stå én gang, i steget der den trengs.
  it('viser tittelen uten lenke når kilden ikke kan lenkes, og forklarer det én gang', async () => {
    renderExtractionControl({ source: reviewSource({ identifiers: [] }) })
    await screen.findByText('Kilden som er brukt')
    const intro = within(document.querySelector('.control-intro') as HTMLElement)
    expect(intro.getByText('Testkilde A: vektendring ved åtte uker')).toBeInTheDocument()
    expect(intro.queryByRole('link')).not.toBeInTheDocument()
    expect(
      screen.getAllByText(
        'Kilden har ingen registrert DOI eller PubMed-ID, så Antidep kan ikke lage en lenke til artikkelen.',
      ),
    ).toHaveLength(1)
  })

  // Innledningen er ikke en delkontroll: ingenting i den kan besvares.
  it('teller ikke innledningen som en delkontroll', async () => {
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

  // Kildetilgangssteget skal inneholde lenken og spørsmålet, og ikke mer.
  // Identifikatoren og representasjonstypen er proveniens; begge sto tidligere
  // midt i flyten, og begge er nå der de hører hjemme.
  it('har verken identifikator, representasjonstype eller gjentatt tittel i steget', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    const step = document.querySelector('.control-step[data-state="active"]') as HTMLElement
    expect(step.textContent).not.toContain('DOI 10.1000/testkilde-a.1')
    expect(step.textContent).not.toContain('Ekstraksjonen bygger på')
    // Tittelen står i innledningen, og gjentas ikke her.
    expect(step.textContent).not.toContain('Testkilde A: vektendring ved åtte uker')
  })

  it('beholder representasjonstypen og identifikatoren under «Tekniske detaljer»', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    const representation = screen.getByText('Ekstraksjonen bygger på fullteksten av kilden.')
    expect(representation.closest('details')).not.toBeNull()
    const identifier = screen.getByText('DOI 10.1000/testkilde-a.1')
    expect(identifier.closest('details')).not.toBeNull()
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
    // `sample_size` er antallet estimatet bygger på, ikke studiens totale
    // inklusjon.
    expect(await step.findByText('Dette estimatet bygger på 240 deltakere.')).toBeInTheDocument()
    expect(screen.queryByText(/Studien inkluderte/)).not.toBeInTheDocument()
    expect(screen.queryByText('sample_size_availability')).not.toBeInTheDocument()
  })

  // Kontrollgrunnlaget skal stå i sin helhet. Et avkortet utdrag ville sendt
  // kontrolløren til artikkelen for å finne resten — som er nøyaktig det
  // forankringen finnes for å slippe.
  it('viser et langt kildeutdrag i sin helhet, uten avkorting', async () => {
    const langt =
      'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly assigned to ' +
      'double-blind treatment with fluoxetine (N = 92), sertraline, (N = 96), or paroxetine ' +
      '(N = 96) for a total of 26 to 32 weeks.'
    renderExtractionControl({
      field_groundings: TEST_FIELD_GROUNDINGS.map((grounding) =>
        grounding['check_field'] === 'intervention_arm'
          ? { ...grounding, source_excerpt: langt }
          : grounding,
      ),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const excerpt = await within(openStep()).findByText(langt)
    expect(excerpt.textContent).toBe(langt)
  })

  // Et utdrag fra en tospaltet artikkel er bare lesbart så lenge linjeskiftene
  // og kolonneavstanden står. Slås blanktegnet sammen, veves nabospalten inn i
  // setningen verdien står i, og kontrolløren kan ikke lenger avgjøre
  // delpunktet av utdraget alene — som er det forankringen finnes for.
  it('beholder linjeskiftene og kolonneavstanden i et tospaltet utdrag', async () => {
    const tospaltet =
      'To systematically assess the effects of extended SSRI        sional disorder, psychotic\n' +
      'treatment on weight, we compared the mean percent            fied, bipolar disorder;\n' +
      'change in weight for all patients who completed the trial.'
    renderExtractionControl({
      field_groundings: TEST_FIELD_GROUNDINGS.map((grounding) =>
        grounding['check_field'] === 'intervention_arm'
          ? { ...grounding, source_excerpt: tospaltet }
          : grounding,
      ),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const excerpt = openStep().querySelector('.field-check__excerpt')
    expect(excerpt?.textContent).toBe(tospaltet)
  })

  // Markupen alene holder ikke: HTML slår blanktegn sammen med mindre stilarket
  // sier noe annet, og jsdom gjengir ingen stil. Regelen prøves derfor der den
  // faktisk bor.
  it('holder utdraget preformatert i stilarket', () => {
    const css = readFileSync(resolve(import.meta.dirname, '../../index.css'), 'utf8')
    const regel = /\.field-check__excerpt\s*\{[^}]*\}/u.exec(css)?.[0] ?? ''
    expect(regel).toMatch(/white-space:\s*pre;/u)
    expect(regel).toMatch(/overflow-x:\s*auto;/u)
  })

  // «Endepunktet» og «Effektmålet» leste som duplikater. De to stegene skal si
  // hver sin ting: hva som ble målt, og hvordan resultatet er uttrykt.
  it('skiller endepunktet fra hvordan resultatet er uttrykt', async () => {
    renderExtractionControl()
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    await within(openStep()).findByText('Behandlingsarmen')
    clickAnswer('Ja')
    expect(
      await within(openStep()).findByText('Det målte endepunktet er vektendring.'),
    ).toBeInTheDocument()
    // Fram til steget om hvordan resultatet er uttrykt.
    for (const field of SEMANTIC_FIELDS.slice(1, 4)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    const step = within(openStep())
    expect(await step.findByText('Hvordan resultatet er uttrykt')).toBeInTheDocument()
    expect(
      step.getByText('Resultatet er uttrykt som gjennomsnittsforskjell, oppgitt i kg.'),
    ).toBeInTheDocument()
  })

  // Kilden oppgir uker. Kontrolløren skal slippe å kontrollregne, og den
  // kanoniske varigheten i databasen skal fortsatt stå.
  it('viser tidsrommet i uker med dagene som eksplisitt omregning', async () => {
    renderExtractionControl({
      extraction: reviewExtraction({ timepoint_min: '182 days', timepoint_max: '224 days' }),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    for (const field of SEMANTIC_FIELDS.slice(0, 8)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    expect(
      await within(openStep()).findByText(
        'Målingen gjelder 26 til 32 uker (registrert som 182 til 224 dager) etter oppstart.',
      ),
    ).toBeInTheDocument()
  })

  /** Går fram til konfidensintervallsteget, som er det siste. */
  async function gaaTilKonfidensintervallet(availability: string): Promise<void> {
    renderExtractionControl({
      extraction: reviewExtraction({
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: availability,
      }),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    for (const field of SEMANTIC_FIELDS.slice(0, 10)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    await within(openStep()).findByText('Konfidensintervallet')
  }

  // En manglende verdi er ikke en tolkning man kan holde opp mot kilden, og
  // aldri en klinisk påstand utledet av fraværet. Det kontrolløren skal
  // bedømme, er den registrerte begrunnelsen.
  it('presenterer en manglende verdi som en begrunnet mangel, og spør om begrunnelsen', async () => {
    await gaaTilKonfidensintervallet('not_applicable')
    const step = within(openStep())
    expect(step.getByText('Hvorfor verdien mangler')).toBeInTheDocument()
    expect(
      step.getByText(
        'Antidep har ikke ført et konfidensintervall for dette estimatet. Ikke aktuelt for dette funnet.',
      ),
    ).toBeInTheDocument()
    expect(step.getByText('Stemmer denne begrunnelsen?')).toBeInTheDocument()
    expect(step.queryByText('Antideps tolkning')).not.toBeInTheDocument()
  })

  // «Ikke rapportert i kilden» er en påstand om kilden som helhet, og den kan
  // ingen avgjøre av ett lokalt utdrag. Spørsmålet er derfor snevret inn til
  // stedet utdraget viser, og flaten sier hva utdraget er.
  it('snevrer et fravær i kilden inn til stedet verdien ville stått', async () => {
    await gaaTilKonfidensintervallet('not_reported')
    const step = within(openStep())
    expect(
      step.getByText('Mangler opplysningen der utdraget viser at den ville stått?'),
    ).toBeInTheDocument()
    expect(step.getByText(/stedet der opplysningen ville stått/)).toBeInTheDocument()
    expect(step.getByText(/ikke lete gjennom resten av kilden/)).toBeInTheDocument()
    // Og ikke det globale ja/nei-spørsmålet, som ingen kunne svart «Ja» på ut
    // fra det flaten viser.
    expect(step.queryByText('Stemmer denne begrunnelsen?')).not.toBeInTheDocument()
  })

  // Funnet fra den tekniske reviewen: «står i kilden, men lar seg ikke lese
  // entydig ut» er det stikk motsatte av at kilden ikke oppgir noe. Et felles
  // fraværsspørsmål ville bedt kontrolløren bekrefte det motsatte av det som
  // er ført.
  it('spør aldri om kilden mangler noe når grunnen er at det ikke lot seg lese ut', async () => {
    await gaaTilKonfidensintervallet('not_extractable')
    const step = within(openStep())
    expect(
      step.getByText(
        'Antidep har ikke ført et konfidensintervall for dette estimatet. Står i kilden, men lar seg ikke lese entydig ut.',
      ),
    ).toBeInTheDocument()
    expect(step.getByText('Stemmer denne begrunnelsen?')).toBeInTheDocument()
    expect(step.queryByText(/kilden ikke oppgir/)).not.toBeInTheDocument()
    // Påstanden gjelder lesningen, ikke kilden som helhet.
    expect(step.queryByText(/påstand om kilden som helhet/)).not.toBeInTheDocument()
  })

  // Effektmålet har ingen fraværskolonne. «Ingenting er ført» er hele
  // påstanden, og den handler om registreringen — ikke om hva kilden oppgir.
  it('behandler et felt uten fraværskolonne som uregistrert, ikke som et fravær i kilden', async () => {
    renderExtractionControl({
      extraction: reviewExtraction({ effect_measure: null }),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    for (const field of SEMANTIC_FIELDS.slice(0, 4)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    const step = within(openStep())
    expect(await step.findByText('Hvordan resultatet er uttrykt')).toBeInTheDocument()
    expect(step.getByText('Ingenting er ført')).toBeInTheDocument()
    expect(
      step.getByText('Antidep har ikke ført et effektmål for dette funnet.'),
    ).toBeInTheDocument()
    expect(step.getByText('Stemmer det at det ikke er noe å føre her?')).toBeInTheDocument()
    expect(step.queryByText(/kilden ikke oppgir/)).not.toBeInTheDocument()
  })

  // Bokføring er ikke en tolkning: «Antidep har ført 1 felt uten verdi» er ikke
  // noe en kontrollør kan sammenligne med en artikkel.
  it('formulerer begrunnelseskontrollen som en mangel, ikke som et antall felter', async () => {
    renderExtractionControl({
      extraction: reviewExtraction({
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: 'not_reported',
      }),
    })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    for (const field of SEMANTIC_FIELDS.slice(0, 3)) {
      await within(openStep()).findByText(field)
      clickAnswer('Ja')
    }
    const step = within(openStep())
    expect(await step.findByText('Begrunnelsen for felter uten verdi')).toBeInTheDocument()
    expect(
      step.getByText(
        'Antidep har ikke ført et konfidensintervall for estimatet. Ikke rapportert i kilden.',
      ),
    ).toBeInTheDocument()
    expect(step.queryByText(/felt uten verdi, med en begrunnelse/)).not.toBeInTheDocument()
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

// ----------------------------------------------------------------------------
// Rekkefølgen: maskinbevis først, semantikk etterpå
//
// Uten beviset har ingen prøvd at utdragene i det hele tatt står i kilden, og
// en kontrollør som gikk gjennom alle feltene, ville fått avvisningen først ved
// lagring (migrasjon 005x).
// ----------------------------------------------------------------------------
describe('Kontrolløkten — maskinbeviset kommer først', () => {
  it('stopper før feltskuffene når ingen maskinell kontroll har prøvd utdragene', async () => {
    renderExtractionControl({ grounding_machine_proved: false })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    const step = within(openStep())
    expect(
      await step.findByText(
        'Ingen maskinell kontroll har ennå prøvd at kildeutdragene står ordrett i denne utgaven av kilden.',
      ),
    ).toBeInTheDocument()
    expect(
      screen.queryByText('Behandlingsarmen', { selector: '.control-step__title' }),
    ).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Lagre og fortsett' })).not.toBeInTheDocument()
  })

  it('sier at kontrolløren bare skal vurdere tolkningen, ikke lete etter utdraget', async () => {
    renderExtractionControl({ grounding_machine_proved: false })
    await screen.findByText('Har du tilgang til fullteksten?')
    clickAnswer('Ja')
    expect(
      await screen.findByText(/Du skal bare vurdere om Antideps tolkning følger av utdraget/),
    ).toBeInTheDocument()
  })
})

describe('Kontrolløkten — en global fraværspåstand dekker ikke seg selv', () => {
  // Kravet fra den tekniske reviewen, i to deler. Kontrollen skal kunne
  // FULLFØRES på korrekt grunnlag — kontrolløren får et spørsmål hen kan svare
  // på fra det flaten viser — men det som ender i `checked_fields`, må være
  // nøyaktig den semantiske påstanden hen har bekreftet
  // (DATABASE_ARCHITECTURE.md §29).
  //
  // «Ikke rapportert i kilden» gjelder hele kilden. Kontrolløren har bekreftet
  // et lokalt fravær, og feltet skal derfor IKKE føres opp som kontrollert.
  it('fører ikke feltet opp som kontrollert, og sier hvorfor', async () => {
    const { rpcCalls } = renderExtractionControl({
      extraction: reviewExtraction({
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: 'not_reported',
      }),
    })
    await answerEverythingYes()

    // Økten er gjennomførbar: alle spørsmålene er besvart fra det flaten viser.
    await screen.findByText('Dette blir registrert som: Bekreftet.')
    // Og den sier at feltet likevel blir stående udekket.
    expect(screen.getByText(/Feltet blir derfor stående som ikke kontrollert/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Lagre og fortsett' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_human_extraction_verification')).toBe(
        true,
      )
    })
    const call = rpcCalls.find((c) => c.name === 'register_human_extraction_verification')
    const args = call?.args as Record<string, unknown>
    const checked = args['p_checked_fields'] as readonly string[]

    // Kjernen: den globale påstanden er ikke bekreftet, og raden påstår ikke at
    // den er det.
    expect(checked).not.toContain('confidence_interval')
    // De feltene kontrolløren faktisk bekreftet semantisk, står der.
    expect(checked).toContain('estimate')
    expect(checked).toContain('intervention_arm')
    // Og begrunnelsen sier hvorfor det ene feltet mangler.
    expect(String(args['p_rationale'])).toMatch(/påstand om kilden som helhet/)
  })

  // Motstykket: en lokal fraværsgrunn bæres av utdraget, og feltet dekkes.
  it('dekker feltet når fraværsgrunnen gjelder funnet og ikke kilden', async () => {
    const { rpcCalls } = renderExtractionControl({
      extraction: reviewExtraction({
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: 'not_applicable',
      }),
    })
    await answerEverythingYes()
    await screen.findByText('Dette blir registrert som: Bekreftet.')
    expect(
      screen.queryByText(/Feltet blir derfor stående som ikke kontrollert/),
    ).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Lagre og fortsett' }))
    await waitFor(() => {
      expect(rpcCalls.some((call) => call.name === 'register_human_extraction_verification')).toBe(
        true,
      )
    })
    const call = rpcCalls.find((c) => c.name === 'register_human_extraction_verification')
    const checked = (call?.args as Record<string, unknown>)['p_checked_fields'] as readonly string[]
    expect(checked).toContain('confidence_interval')
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
    // Nøyaktig de elleve feltene kontrolløren faktisk bekreftet. De to
    // provenansfeltene dekkes av maskinens egen rad; gatens G5b leser unionen
    // (migrasjon 005y).
    expect(args['p_checked_fields']).not.toContain('raw_extraction')
    expect(args['p_checked_fields']).not.toContain('source_locator')
    expect((args['p_checked_fields'] as string[]).length).toBe(11)
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
