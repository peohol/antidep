import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  callRpc,
  classifyGatewayFailure,
  describeGatewayFailure,
  GatewayFailure,
  flushPendingDiagnostics,
  setTechnicalSink,
  transportShape,
  type GatewayFailureKind,
  type TechnicalDetail,
} from './gateway'
import { clearOutbox, pending } from './diagnostics-outbox'
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
    auth: {
      getSession: () =>
        Promise.resolve({ data: { session: { access_token: 'brukerens-egen-token' } } }),
    },
  }
  return { client: fake as unknown as AntidepClient, calls }
}

/** Det nettleseren faktisk sendte til `/diagnostics`, uten å røre nettet. */
function fangLevering(svar: { ok: boolean } | 'ryker'): {
  readonly sendt: { url: string; body: string }[]
  restore: () => void
} {
  const sendt: { url: string; body: string }[] = []
  const original = globalThis.fetch
  Object.defineProperty(globalThis, 'fetch', {
    configurable: true,
    value: (url: string, init: { body: string }) => {
      sendt.push({ url, body: init.body })
      return svar === 'ryker' ? Promise.reject(new Error('nettet ryker')) : Promise.resolve(svar)
    },
  })
  return {
    sendt,
    restore: () => {
      Object.defineProperty(globalThis, 'fetch', { configurable: true, value: original })
    },
  }
}

afterEach(() => {
  setTechnicalSink(null)
  // Utboksen lever i nettleserens eget lager og overlever mellom prøver. Den
  // skal ikke overleve noe som helst her.
  clearOutbox()
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

  // Selvmeldingen bærer fire maskinidentifikatorer og ingen tekst. Operasjonen
  // og koden er det som gjør den rå årsaken varig gjenfinnbar for en teknisk
  // agent — men ingen av dem kan bære et filnavn, en adresse eller en del av et
  // svar, og feilteksten selv følger aldri med.
  it('sender bare maskinidentifikatorer med selvmeldingen, aldri feilteksten', async () => {
    const { client: db, calls } = client({
      noe: { error: { code: 'PGRST301', message: 'hemmelig' } },
    })
    await callRpc(db, { fn: 'noe', area: 'full_text_intake', parse: () => undefined }).catch(
      () => undefined,
    )
    const report = calls.find((call) => call.fn === 'report_technical_problem')
    const args = report?.args as Record<string, unknown>
    expect(args.p_area).toBe('full_text_intake')
    expect(args.p_kind).toBe('unavailable')
    expect(args.p_operation).toBe('noe')
    expect(args.p_code).toBe('PGRST301')
    expect(args.p_transport).toBe('unknown')

    // Meldingen om problemet bærer ingen tekst i det hele tatt. Den rå årsaken
    // går sin egen vei, til `/diagnostics`.
    expect(args.p_detail).toBeUndefined()
    expect(JSON.stringify(args)).not.toContain('hemmelig')
  })

  // Koden mangler nettopp når svaret aldri kom. Uten transportformen ville en
  // teknisk agent sett *at* et kall sviktet, uten noe som helst om hvordan.
  // Formen leses av hva feilen *er*, aldri av hva den sier — og det er nettopp
  // derfor den kan sendes videre.
  it.each([
    [new TypeError('Failed to fetch'), 'unavailable', 'network'],
    [{ status: 503 }, 'unavailable', 'http'],
    [{ name: 'AbortError' }, 'unavailable', 'aborted'],
    [{ name: 'TimeoutError' }, 'unavailable', 'timeout'],
    [new Error('hva som helst'), 'unreadable_answer', 'contract'],
    ['noe rart', 'unavailable', 'unknown'],
  ])('leser formen på svikten som en maskinverdi (%#)', (cause, kind, expected) => {
    expect(transportShape(cause, kind as GatewayFailureKind)).toBe(expected)
  })

  it('sender transportformen med når svaret aldri kom, og koden derfor mangler', async () => {
    const calls: { fn: string; args: unknown }[] = []
    const nettetErBorte = {
      rpc: (fn: string, args: unknown) => {
        calls.push({ fn, args })
        return fn === 'noe'
          ? Promise.reject(new TypeError('Failed to fetch'))
          : Promise.resolve({ data: null, error: null })
      },
    } as unknown as AntidepClient

    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await callRpc(nettetErBorte, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )
    spy.mockRestore()

    const report = calls.find((call) => call.fn === 'report_technical_problem')
    const args = report?.args as Record<string, unknown>
    expect(args.p_code).toBeNull()
    expect(args.p_http_status).toBeNull()
    expect(args.p_transport).toBe('network')
  })

  // Databasen klipper uansett, men en stack på flere hundre kilobyte skal ikke
  // sendes over nettet for å bli kastet i andre enden — og `sendBeacon` har sin
  // egen, mindre kø å ta hensyn til.
  it('klipper den rå årsaken før den sendes', async () => {
    const seen: TechnicalDetail[] = []
    setTechnicalSink((entry) => seen.push(entry))
    const { client: db } = client({ noe: { data: [] } })
    await callRpc(db, {
      fn: 'noe',
      area: 'work_queue',
      parse: () => {
        throw new Error('x'.repeat(20000))
      },
    }).catch(() => undefined)

    expect(seen[0]?.detail).toHaveLength(4000)
  })

  // HTTP-statusen står i konvolutten rundt svaret og ikke i feilen, og en 503
  // og en 401 er to helt forskjellige driftsproblemer.
  it('tar med HTTP-statusen tjenesten faktisk svarte med', async () => {
    const calls: { fn: string; args: unknown }[] = []
    const svarer503 = {
      rpc: (fn: string, args: unknown) => {
        calls.push({ fn, args })
        return Promise.resolve(
          fn === 'noe'
            ? { data: null, error: { code: 'PGRST301' }, status: 503 }
            : { data: null, error: null, status: 200 },
        )
      },
    } as unknown as AntidepClient

    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await callRpc(svarer503, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )
    spy.mockRestore()

    const report = calls.find((call) => call.fn === 'report_technical_problem')
    expect((report?.args as { p_http_status: unknown }).p_http_status).toBe(503)
  })

  // En kode databasen ville avvist, er ikke verdt å presse gjennom: meldingen
  // ville forsvunnet helt, og da hadde ingenting blitt registrert.
  it('lar koden være når den ikke har en kodes form', async () => {
    const { client: db, calls } = client({
      noe: { error: { code: 'noe helt annet', message: 'x' } },
    })
    await callRpc(db, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )
    const report = calls.find((call) => call.fn === 'report_technical_problem')
    expect((report?.args as { p_code: unknown }).p_code).toBeNull()
  })

  // Dette er hele grunnen til at den rå årsaken har sin egen vei: den skal nå
  // fram selv når Data API-et er borte, altså nettopp når den trengs.
  it('leverer den rå årsaken på sin egen vei når hele Data API-veien er nede', async () => {
    const levering = fangLevering({ ok: true })
    const nedeHeltUt = {
      rpc: () => Promise.reject(new TypeError('Failed to fetch')),
      auth: {
        getSession: () =>
          Promise.resolve({ data: { session: { access_token: 'brukerens-egen-token' } } }),
      },
    } as unknown as AntidepClient

    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await callRpc(nedeHeltUt, {
      fn: 'public_work_board',
      area: 'work_queue',
      parse: () => undefined,
    }).catch(() => undefined)
    await vi.waitFor(() => expect(levering.sendt).toHaveLength(1))
    spy.mockRestore()

    expect(levering.sendt[0]?.url).toBe('/diagnostics')
    const sendt = JSON.parse(levering.sendt[0]?.body ?? '{}') as Record<string, unknown>
    expect(sendt.detail).toContain('Failed to fetch')
    expect(sendt.operation).toBe('public_work_board')
    // Tokenen er brukerens egen og allerede i fanen — ingen klienthemmelighet.
    expect(sendt.accessToken).toBe('brukerens-egen-token')
    // Bekreftet levert, altså ute av utboksen.
    await vi.waitFor(() => expect(pending()).toHaveLength(0))
    levering.restore()
  })

  // Og dette er grunnen til at utboksen finnes: er lagringen bak ruten også
  // nede, skal årsaken utsettes, ikke mistes.
  it('beholder den rå årsaken når leveringen ikke kom fram, og sender den senere', async () => {
    const ryker = fangLevering('ryker')
    const nede = {
      rpc: () => Promise.reject(new TypeError('Failed to fetch')),
      auth: {
        getSession: () =>
          Promise.resolve({ data: { session: { access_token: 'brukerens-egen-token' } } }),
      },
    } as unknown as AntidepClient

    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await callRpc(nede, {
      fn: 'public_work_board',
      area: 'work_queue',
      parse: () => undefined,
    }).catch(() => undefined)
    await vi.waitFor(() => expect(ryker.sendt).toHaveLength(1))
    spy.mockRestore()
    ryker.restore()

    // Fortsatt i utboksen, med årsaken i behold.
    expect(pending()).toHaveLength(1)
    expect(pending()[0]?.detail).toContain('Failed to fetch')

    // Og neste gang flaten åpnes, går restansen med.
    const senere = fangLevering({ ok: true })
    flushPendingDiagnostics(nede)
    await vi.waitFor(() => expect(senere.sendt).toHaveLength(1))
    await vi.waitFor(() => expect(pending()).toHaveLength(0))
    expect(JSON.parse(senere.sendt[0]?.body ?? '{}').detail).toContain('Failed to fetch')
    senere.restore()
  })

  // En observasjon som ikke kan tilskrives noen, skal ikke sendes: det ville
  // vært en åpen skrivevei. Den blir liggende, så en fornyet innlogging tar den.
  it('sender ingenting når det ikke finnes noen innlogget bruker', async () => {
    const levering = fangLevering({ ok: true })
    const uinnlogget = {
      rpc: () => Promise.resolve({ data: null, error: { code: 'PGRST301' } }),
      auth: { getSession: () => Promise.resolve({ data: { session: null } }) },
    } as unknown as AntidepClient

    const spy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    await callRpc(uinnlogget, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )
    await Promise.resolve()
    await Promise.resolve()
    spy.mockRestore()

    expect(levering.sendt).toHaveLength(0)
    expect(pending()).toHaveLength(1)
    levering.restore()
  })

  // Flaten lukker ingenting. En selvmeldt rad gjelder så lenge den fornyes, og
  // det er databasen som avgjør når den er over. Et minne i fanen ville vært
  // borte ved første sideoppfriskning — og da hadde meldingen blitt stående.
  it('lukker ingenting selv, heller ikke når kallet går gjennom igjen', async () => {
    const svikter = client({ noe: { error: { code: 'PGRST301' } } })
    await callRpc(svikter.client, { fn: 'noe', area: 'work_queue', parse: () => undefined }).catch(
      () => undefined,
    )
    expect(svikter.calls.map((call) => call.fn)).toContain('report_technical_problem')

    const virker = client({ noe: { data: [] } })
    await callRpc(virker.client, { fn: 'noe', area: 'work_queue', parse: () => undefined })
    expect(virker.calls.map((call) => call.fn)).toEqual(['noe'])
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
