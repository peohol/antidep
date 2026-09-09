// ============================================================================
// Kildeadressen: trykkbar når den kan åpnes, aldri ellers
//
// Den siste påstanden er sikkerhetskritisk. En adresse er registrert av et
// menneske eller en agent og er utrygg inndata; `javascript:` i en href kjører i
// sidens egen opprinnelse.
// ============================================================================

import { describe, expect, it } from 'vitest'
import { describeSourceAddress } from './source-address'

describe('describeSourceAddress', () => {
  it('gjør en http- og https-adresse til en lenke', () => {
    expect(describeSourceAddress('https://eksempel.invalid/artikkel')).toEqual({
      kind: 'link',
      href: 'https://eksempel.invalid/artikkel',
      text: 'https://eksempel.invalid/artikkel',
    })
    expect(describeSourceAddress('http://eksempel.invalid/a')?.kind).toBe('link')
  })

  it('viser en adresse som ikke er en URL som tekst', () => {
    expect(describeSourceAddress('Riksarkivet, boks 12')).toEqual({
      kind: 'text',
      text: 'Riksarkivet, boks 12',
    })
  })

  it('gjør aldri et annet skjema enn http og https til en lenke', () => {
    for (const raw of [
      'javascript:alert(1)',
      'data:text/html;base64,PHNjcmlwdD4=',
      'file:///etc/passwd',
      'vbscript:msgbox(1)',
    ]) {
      expect(describeSourceAddress(raw)).toEqual({ kind: 'text', text: raw })
    }
  })

  it('leser fravær som fravær, ikke som en tom lenke', () => {
    expect(describeSourceAddress(null)).toBeNull()
    expect(describeSourceAddress('   ')).toBeNull()
  })
})
