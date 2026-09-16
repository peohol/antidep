// ============================================================================
// Den private diagnostikk-kanalen, prøvd mot det den skal garantere
//
// To ting betyr noe her, og de trekker hver sin vei: at den rå årsaken faktisk
// blir bevart et sted som overlever at fanen lukkes, og at ingenting går ut av
// nettleseren når ingen har bedt om det.
// ============================================================================

import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  createDiagnosticsSink,
  readDiagnosticsEndpoint,
  type DiagnosticsEnvelope,
} from './diagnostics-sink'
import type { TechnicalDetail } from './gateway'

const OBSERVASJON: TechnicalDetail = {
  area: 'work_queue',
  operation: 'public_work_board',
  kind: 'unavailable',
  code: null,
  httpStatus: null,
  transport: 'network',
  detail: 'TypeError: Failed to fetch\n    at callRpc (gateway.ts:1:1)',
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('adressen kanalen leser', () => {
  it('er ingen når ingen er valgt', () => {
    expect(readDiagnosticsEndpoint({})).toBeNull()
    expect(readDiagnosticsEndpoint({ VITE_ANTIDEP_DIAGNOSTICS_URL: '   ' })).toBeNull()
  })

  it('tar imot en https-adresse', () => {
    expect(
      readDiagnosticsEndpoint({ VITE_ANTIDEP_DIAGNOSTICS_URL: 'https://logg.eksempel/ny' }),
    ).toBe('https://logg.eksempel/ny')
  })

  // Innholdet er nettopp det som ikke skal kunne leses av andre underveis.
  it('avviser en adresse uten https', () => {
    expect(() =>
      readDiagnosticsEndpoint({ VITE_ANTIDEP_DIAGNOSTICS_URL: 'http://logg.eksempel/ny' }),
    ).toThrow(/https/)
  })

  // På localhost finnes det ikke noe «underveis», og en utvikler skal kunne se
  // hva som faktisk sendes.
  it('slipper gjennom en lokal adresse under utvikling', () => {
    expect(
      readDiagnosticsEndpoint({ VITE_ANTIDEP_DIAGNOSTICS_URL: 'http://localhost:9000/diag' }),
    ).toBe('http://localhost:9000/diag')
  })

  // En kanal som stille lot være å virke, ville vært verre enn ingen: den som
  // satte variabelen, ville trodd årsakene ble bevart.
  it('feiler høyt på en verdi som er satt men ugyldig', () => {
    expect(() => readDiagnosticsEndpoint({ VITE_ANTIDEP_DIAGNOSTICS_URL: 'ikke en url' })).toThrow(
      /gyldig URL/,
    )
  })
})

describe('sluket', () => {
  it('sender ingenting ut av nettleseren når ingen adresse er valgt', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const sendt: string[] = []
    createDiagnosticsSink(null, (_endpoint, body) => sendt.push(body))(OBSERVASJON)

    expect(sendt).toHaveLength(0)
    // Konsollen skrives til uansett: den virker når et endepunkt ikke gjør det.
    expect(spy).toHaveBeenCalledOnce()
  })

  // Dette er hele poenget med kanalen: stacken og den faktiske meldingen
  // overlever at fanen lukkes.
  it('sender den rå årsaken til endepunktet når et er valgt', () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const sendt: { endpoint: string; body: string }[] = []
    createDiagnosticsSink('https://logg.eksempel/ny', (endpoint, body) =>
      sendt.push({ endpoint, body }),
    )(OBSERVASJON)

    expect(sendt).toHaveLength(1)
    expect(sendt[0]?.endpoint).toBe('https://logg.eksempel/ny')
    const envelope = JSON.parse(sendt[0]?.body ?? '{}') as DiagnosticsEnvelope
    expect(envelope.detail).toContain('Failed to fetch')
    expect(envelope.operation).toBe('public_work_board')
    expect(envelope.transport).toBe('network')
    expect(Date.parse(envelope.occurredAt)).not.toBeNaN()
  })

  // Kanalen skal aldri bli en ny feil på toppen av den som allerede er vist.
  it('svelger en kanal som selv svikter', () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined)
    expect(() =>
      createDiagnosticsSink('https://logg.eksempel/ny', () => {
        throw new Error('endepunktet er nede')
      })(OBSERVASJON),
    ).not.toThrow()
  })
})
