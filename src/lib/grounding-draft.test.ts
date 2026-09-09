// ============================================================================
// Forankringen slik skjemaet samler den inn
//
// Halvferdige forankringer avvises. En peker uten utdrag sier ikke hva som står
// der, og et utdrag uten peker kan ikke etterprøves — og i kontrolløkten ville
// begge sett ut som en komplett forankring.
// ============================================================================

import { describe, expect, it } from 'vitest'
import { collectFieldGroundings } from './grounding-draft'

const label = (field: string) => `felt «${field}»`

describe('collectFieldGroundings', () => {
  it('tar med de feltene som er fylt helt ut, og trimmer dem', () => {
    const result = collectFieldGroundings(
      {
        estimate: {
          excerpt: '  Mean difference 1.7 kg.  ',
          locator: ' Tabell 2 ',
          justification: ' Tallet står i resultatraden. ',
        },
      },
      label,
    )
    expect(result).toEqual({
      status: 'ok',
      groundings: [
        {
          checkField: 'estimate',
          sourceExcerpt: 'Mean difference 1.7 kg.',
          sourceLocator: 'Tabell 2',
          justification: 'Tallet står i resultatraden.',
        },
      ],
    })
  })

  it('hopper over felter som er helt tomme', () => {
    const result = collectFieldGroundings(
      { estimate: { excerpt: '', locator: '', justification: '' } },
      label,
    )
    expect(result).toEqual({ status: 'ok', groundings: [] })
  })

  it('avviser en halvferdig forankring, og navngir feltet', () => {
    const result = collectFieldGroundings(
      { estimate: { excerpt: 'Mean difference 1.7 kg.', locator: '', justification: '' } },
      label,
    )
    expect(result.status).toBe('incomplete')
    expect(result.status === 'incomplete' ? result.message : '').toContain('felt «estimate»')
  })
})
