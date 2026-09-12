// ============================================================================
// Utdraget gjort lesbart, uten at et ord er endret
//
// Prøvene handler om ett krav: kontrolløren skal lese den teksten som faktisk
// ble kontrollert, i en form som er lesbar på en telefon. Det som skiller de to
// tilfellene, er grensen den kanoniske representasjonen setter — én blank linje
// mellom to uavhengige tekstblokker, ett linjeskift inne i en blokk
// (`src/agents/reading-order.ts`) — og det er den samme grensen den ordrette
// kontrollen ikke lar et sitat krysse (`src/agents/extraction-checks.ts`).
// ============================================================================

import { describe, expect, it } from 'vitest'

import { excerptKeepsLayout, readableExcerptParagraphs } from './readable-excerpt'

describe('readableExcerptParagraphs', () => {
  it('slår linjeombrekkingen fra PDF-en sammen til mellomrom', () => {
    expect(
      readableExcerptParagraphs(
        'Patients (N = 284) with major depressive disorder\nwere randomly assigned.',
      ),
    ).toEqual(['Patients (N = 284) with major depressive disorder were randomly assigned.'])
  })

  it('beholder en blokkgrense som et eget avsnitt', () => {
    expect(
      readableExcerptParagraphs('J Clin Psychiatry 61:11\n\nPatients were randomised.'),
    ).toEqual(['J Clin Psychiatry 61:11', 'Patients were randomised.'])
  })

  it('regner et sideskift som en blokkgrense', () => {
    expect(readableExcerptParagraphs('Weight increased.\n\fTable 2. Adverse events.')).toEqual([
      'Weight increased.',
      'Table 2. Adverse events.',
    ])
  })

  it('slår også sammen en kolonneavstand, og er derfor ikke veien for en `-layout`-tekst', () => {
    // Dette er nettopp grunnen til at `excerptKeepsLayout` finnes: veggen av
    // mellomrom mellom to spalter forsvinner her, og da leser to uavhengige
    // spalter som én setning. Et utdrag fra en representasjon som fortsatt
    // bærer papirets plassering, skal derfor ikke gjennom denne funksjonen.
    expect(
      readableExcerptParagraphs(
        'Background: The effects of extended selec-        is also a major cause of',
      ),
    ).toEqual(['Background: The effects of extended selec- is also a major cause of'])
  })

  it('endrer ingen ord, ingen tegnsetting og ingen orddeling', () => {
    const utdrag = 'The effects of extended selec-\ntive serotonin reuptake inhibitor treatment.'
    const [avsnitt] = readableExcerptParagraphs(utdrag)
    // Orddelingen står: å sette «selec-» og «tive» sammen ville laget et ord som
    // ikke står i dokumentet, og «Long-» pluss «Term» viser hvorfor.
    expect(avsnitt).toContain('selec- tive')
    expect(avsnitt?.replaceAll(' ', '')).toBe(utdrag.replaceAll(/\s/g, ''))
  })

  it('gir ingen avsnitt for et utdrag uten innhold', () => {
    expect(readableExcerptParagraphs('   \n\n  ')).toEqual([])
  })
})

describe('excerptKeepsLayout', () => {
  const recipe = (transform: string | null) => ({ textExtraction: { transform } })

  it('lar en tekst som er verktøyets utdata ordrett, stå som den står', () => {
    // `-layout` uten etterbehandling: venstre og høyre spalte ligger på den
    // samme tekstlinjen, og avstanden mellom dem er det eneste synlige
    // varselet om at ordene ikke hører sammen.
    expect(excerptKeepsLayout(recipe(null))).toBe(true)
  })

  it('lar en tekst Antidep har bygget leserekkefølgen av, flyte', () => {
    expect(excerptKeepsLayout(recipe('antidep-reading-order@2'))).toBe(false)
    expect(excerptKeepsLayout(recipe('antidep-reading-order@1'))).toBe(false)
  })

  it('lar en representasjon som ikke er utledet av et dokument, flyte', () => {
    // Teksten som lå på adressen — et sammendrag, for eksempel — har ingen
    // spalter å veve sammen.
    expect(excerptKeepsLayout(null)).toBe(false)
  })
})
