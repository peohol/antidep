import { describe, expect, it } from 'vitest'

import { localInputValueToIso, nowAsLocalInputValue } from './local-datetime'

describe('nowAsLocalInputValue', () => {
  it('gir formen datetime-local forventer', () => {
    expect(nowAsLocalInputValue(new Date(2026, 8, 7, 9, 5))).toBe('2026-09-07T09:05')
  })

  it('nullpadder måned, dag, time og minutt', () => {
    expect(nowAsLocalInputValue(new Date(2026, 0, 2, 3, 4))).toBe('2026-01-02T03:04')
  })
})

describe('localInputValueToIso', () => {
  it('gir et tidspunkt med sone, tolket i nettleserens egen sone', () => {
    const iso = localInputValueToIso('2026-09-07T09:15')
    expect(iso).not.toBeNull()
    expect(new Date(iso ?? '').getTime()).toBe(new Date(2026, 8, 7, 9, 15).getTime())
  })

  it('gir null for et tomt felt', () => {
    expect(localInputValueToIso('')).toBeNull()
    expect(localInputValueToIso('   ')).toBeNull()
  })

  it('gir null for noe som ikke er et tidspunkt', () => {
    expect(localInputValueToIso('ikke en dato')).toBeNull()
  })
})
