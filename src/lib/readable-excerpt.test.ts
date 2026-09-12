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

import { readableExcerptParagraphs } from './readable-excerpt'

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

  it('fjerner kolonneavstanden fra et utdrag hentet ut med den gamle oppskriften', () => {
    // Historiske kildeversjoner bærer fortsatt `-layout`-teksten, og utdragene
    // fra dem skal være lesbare uten at noen ord forsvinner.
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
