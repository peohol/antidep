// ============================================================================
// Utboksen, og det ene den må tåle: å bli delt
//
// Flere mennesker deler ofte den samme maskinen på et kontor, og de deler da
// også `localStorage`. Et felles tak ville gjort at den som sist møtte en feil,
// skjøv ut observasjonene til den som møtte en før — uten at noen av dem kunne
// se det skje, og uten at noe ble meldt. Prøvene her er på nettopp den grensen.
// ============================================================================

import { beforeEach, describe, expect, it } from 'vitest'

import {
  clearOutbox,
  forget,
  MAX_PENDING,
  MAX_PENDING_TOTAL,
  pending,
  pendingFor,
  remember,
  type PendingDiagnostic,
} from './diagnostics-outbox'

const A = '9f000000-0000-4000-8000-0000000000a1'
const B = '9f000000-0000-4000-8000-0000000000b2'

let teller = 0

function observasjon(
  userId: string | null,
  detail = 'TypeError: Failed to fetch',
): PendingDiagnostic {
  teller += 1
  return {
    eventId: `00000000-0000-4000-8000-${String(teller).padStart(12, '0')}`,
    userId,
    area: 'work_queue',
    kind: 'unavailable',
    operation: 'public_work_board',
    code: null,
    httpStatus: null,
    transport: 'network',
    detail,
  }
}

describe('utboksen', () => {
  beforeEach(() => {
    clearOutbox()
    teller = 0
  })

  it('leverer bare det som tilhører den som spør', () => {
    remember(observasjon(A, 'a-1'))
    remember(observasjon(B, 'b-1'))
    remember(observasjon(null, 'anonym-1'))

    expect(pendingFor(A).map((e) => e.detail)).toEqual(['a-1'])
    expect(pendingFor(B).map((e) => e.detail)).toEqual(['b-1'])
    expect(pendingFor(null).map((e) => e.detail)).toEqual(['anonym-1'])
  })

  it('holder taket for hver avsender for seg', () => {
    for (let i = 0; i < MAX_PENDING + 5; i += 1) {
      remember(observasjon(A, `a-${String(i)}`))
    }
    expect(pendingFor(A)).toHaveLength(MAX_PENDING)
    // Den eldste faller ut først: en ny årsak sier mer om hva som skjer nå.
    expect(pendingFor(A)[0]?.detail).toBe('a-5')
    expect(pendingFor(A).at(-1)?.detail).toBe(`a-${String(MAX_PENDING + 4)}`)
  })

  // Dette er hele poenget. Med ett felles tak ville A vært tom her.
  it('lar ikke én avsender skyve ut en annens', () => {
    remember(observasjon(A, 'a-den-eneste'))
    for (let i = 0; i < MAX_PENDING * 3; i += 1) {
      remember(observasjon(B, `b-${String(i)}`))
    }

    expect(pendingFor(A).map((e) => e.detail)).toEqual(['a-den-eneste'])
    expect(pendingFor(B)).toHaveLength(MAX_PENDING)
  })

  it('lar heller ikke den anonyme skyve ut en innlogget', () => {
    remember(observasjon(A, 'a-den-eneste'))
    for (let i = 0; i < MAX_PENDING * 3; i += 1) {
      remember(observasjon(null, `anonym-${String(i)}`))
    }

    expect(pendingFor(A).map((e) => e.detail)).toEqual(['a-den-eneste'])
    expect(pendingFor(null)).toHaveLength(MAX_PENDING)
  })

  // `localStorage` er en delt og liten ressurs. Blir det for mye totalt, faller
  // den eldste hos den som har flest — aldri hos den som har få.
  it('tar fra den største når lageret under ett blir for stort', () => {
    const avsendere = Array.from({ length: 10 }, (_, i) => `bruker-${String(i)}`)
    for (const avsender of avsendere) {
      for (let i = 0; i < MAX_PENDING; i += 1) {
        remember(observasjon(avsender, `${avsender}-${String(i)}`))
      }
    }

    expect(pending().length).toBeLessThanOrEqual(MAX_PENDING_TOTAL)
    // Jevnt fordelt, og ingen er tømt for at en annen skulle få plass.
    for (const avsender of avsendere) {
      expect(pendingFor(avsender).length).toBeGreaterThan(0)
    }
  })

  it('glemmer bare den ene observasjonen', () => {
    remember(observasjon(A, 'a-1'))
    const andre = observasjon(A, 'a-2')
    remember(andre)
    remember(observasjon(B, 'b-1'))

    forget(andre.eventId)

    expect(pendingFor(A).map((e) => e.detail)).toEqual(['a-1'])
    expect(pendingFor(B)).toHaveLength(1)
  })

  it('legger den samme observasjonen bort én gang', () => {
    const en = observasjon(A, 'a-1')
    remember(en)
    remember(en)
    expect(pendingFor(A)).toHaveLength(1)
  })
})
