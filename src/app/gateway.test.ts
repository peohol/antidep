import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  callRpc,
  classifyGatewayFailure,
  describeGatewayFailure,
  GatewayFailure,
  setTechnicalSink,
  type TechnicalDetail,
} from './gateway'
import type { AntidepClient } from '../lib/supabase'

/**
 * En database som svarer nøyaktig det prøven ber om.
 *
 * `rpc` er den eneste metoden gatewayene bruker, så doblingen trenger ikke være
 * mer enn den. Kallene registreres, slik at prøven kan se hva som faktisk ble
 * sendt — særlig selvmeldingen, som aldri skal bære tekst.
 */
function client(answers: Record<string, { data?: unknown; error?: unknown }>): {
  readonly client: AntidepClient
  readonly calls: { fn: string; args: unknown }[]
} {
  const calls: { fn: string; args: unknown }[] = []
  const fake = {
    rpc: (fn: string, args: unknown) => {
      calls.push({ fn, args })
      const answer = answers[fn] ?? { error: { code: 'PGRST202', message: 'ukjent funksjon' } }
      return Promise.resolve({ data: answer.data ?? null, error: answer.error ?? null })
    },
  }
  return { client: fake as unknown as AntidepClient, calls }
}

afterEach(() => {
  setTechnicalSink(null)
})

describe('klassifiseringen av en svikt', () => {
  it('kjenner igjen Antideps egne, bevisste avvisninger', () => {
    expect(classifyGatewayFailure({ code: '42501' })).toBe('not_authorized')
    expect(classifyGatewayFailure({ code: '02000' })).toBe('not_found')
    expect(classifyGatewayFailure({ code: '22023' })).toBe('invalid_input')
    expect(classifyGatewayFailure({ code: '23001' })).toBe('rejected')
  })

  // Alt annet skal bli «Antidep svarte ikke». En ukjent svikt skal behandles
  // som noe flaten ikke forstår, ikke som noe den later som om den forstår.
  it('behandler alt annet som at Antidep ikke svarte', () => {
    expect(classifyGatewayFailure({ code: 'PGRST301', message: 'JWT expired' })).toBe('unavailable')
    expect(classifyGatewayFailure(new TypeError('Failed to fetch'))).toBe('unavailable')
    expect(classifyGatewayFailure(null)).toBe('unavailable')
  })

  it('lar flaten skrive sin egen setning, og har en sann standardsetning', () => {
    expect(describeGatewayFailure('unavailable')).toMatch(/svarte ikke/)
    expect(describeGatewayFailure('unavailable', { unavailable: 'Egen setning.' })).toBe(
      'Egen setning.',
    )
  })
})

describe('kallet gjennom gatewayen', () => {
  it('leser svaret med den samme strengheten som en fil', async () => {
    const { client: db } = client({ noe: { data: [{ verdi: 1 }] } })
    await expect(
      callRpc(db, {
        fn: 'noe',
        area: 'work_queue',
        parse: (data) => {
          if (!Array.isArray(data)) {
            throw new Error('ikke en liste')
          }
          return data.length
        },
      }),
    ).resolves.toBe(1)
  })

  // Kjernen i issue #99 punkt 8: databasens egen tekst skal aldri nå fram til
  // et menneske, uansett hvor god den er.
  it('viser aldri databasens egen feiltekst', async () => {
    const { client: db } = client({
      noe: {
        error: {
          code: 'PGRST301',
          message: 'JWT expired',
          details: 'null value in column "id" violates not-null constraint',
          hint: 'SQLSTATE 23502',
        },
      },
    })

    const failure = await callRpc(db, {
      fn: 'noe',
      area: 'work_queue',
      parse: () => undefined,
    }).catch((cause: unknown) => cause)

    expect(failure).toBeInstanceOf(GatewayFailure)
    const message = (failure as GatewayFailure).message
    expect(message).toBe('Antidep svarte ikke akkurat nå. Prøv igjen om litt.')
    for (const teknisk of ['JWT', 'PGRST', 'SQLSTATE', 'not-null', 'column']) {
      expect(message).not.toContain(teknisk)
    }
  })

  it('sender den rå årsaken til observability, og bare dit', async () => {
    const seen: TechnicalDetail[] = []
    setTechnicalSink((entry) => seen.push(entry))
    const { client: db } = client({ noe: { error: { code: 'PGRST301', message: 'JWT expired' } } })

    await callRpc(db, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )

    expect(seen).toHaveLength(1)
    expect(seen[0]?.detail).toContain('JWT expired')
    expect(seen[0]?.operation).toBe('noe')
    expect(seen[0]?.code).toBe('PGRST301')
  })

  // En manglende rettighet og en bevisst avvisning er ikke tekniske problemer.
  // De skal derfor ikke kunne få merket i navigasjonen til å lyse.
  it('melder bare tekniske svikt videre til problemoversikten', async () => {
    const utilgjengelig = client({ noe: { error: { code: 'PGRST301' } } })
    await callRpc(utilgjengelig.client, {
      fn: 'noe',
      area: 'work_queue',
      parse: () => undefined,
    }).catch(() => undefined)
    expect(utilgjengelig.calls.map((call) => call.fn)).toContain('report_technical_problem')

    for (const code of ['42501', '23001', '22023']) {
      const avvist = client({ noe: { error: { code } } })
      await callRpc(avvist.client, {
        fn: 'noe',
        area: 'work_queue',
        parse: () => undefined,
      }).catch(() => undefined)
      expect(avvist.calls.map((call) => call.fn)).not.toContain('report_technical_problem')
    }
  })

  it('sender ingen tekst med selvmeldingen — bare to lukkede vokabularer', async () => {
    const { client: db, calls } = client({
      noe: { error: { code: 'PGRST301', message: 'hemmelig' } },
    })
    await callRpc(db, { fn: 'noe', area: 'full_text_intake', parse: () => undefined }).catch(
      () => undefined,
    )
    const report = calls.find((call) => call.fn === 'report_technical_problem')
    expect(report?.args).toEqual({ p_area: 'full_text_intake', p_kind: 'unavailable' })
  })

  // Et svar som ikke lar seg lese, er like alvorlig som et svar som ikke kom:
  // begge betyr at flaten ikke vet hva den viser.
  it('behandler et uleselig svar som en teknisk svikt', async () => {
    const { client: db, calls } = client({ noe: { data: { feil: 'form' } } })
    const failure = await callRpc(db, {
      fn: 'noe',
      area: 'work_queue',
      parse: () => {
        throw new Error('Arbeidsoversikten er ugyldig: svaret er ikke en liste.')
      },
    }).catch((cause: unknown) => cause)

    expect((failure as GatewayFailure).kind).toBe('unreadable_answer')
    expect((failure as GatewayFailure).message).not.toContain('ugyldig')
    expect(calls.map((call) => call.fn)).toContain('report_technical_problem')
  })

  it('svelger en selvmelding som selv feiler, framfor å legge en feil på en feil', async () => {
    const { client: db } = client({
      noe: { error: { code: 'PGRST301' } },
      report_technical_problem: { error: { code: '42501' } },
    })
    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await expect(
      callRpc(db, { fn: 'noe', area: 'work_queue', parse: () => undefined }),
    ).rejects.toBeInstanceOf(GatewayFailure)
    spy.mockRestore()
  })
})
