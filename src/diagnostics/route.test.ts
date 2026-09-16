// ============================================================================
// Diagnostikkruten, prøvd mot det den faktisk skal tåle
//
// Ruten finnes fordi den rå årsaken ikke kan gå den samme veien som kallet som
// nettopp sviktet. Prøvene her handler derfor mest om hva som skjer når noe går
// galt: en kropp som ikke stemmer, et miljø som mangler, en database som svarer
// 503. I alle tilfeller skal ruten være taus utad og aldri kaste.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseDiagnosticEnvelope } from './envelope.ts'
import { serveDiagnostics, type ForwardDiagnostic, type ForwardTarget } from './route.ts'

const MILJØ = {
  ANTIDEP_SUPABASE_URL: 'https://prosjekt.supabase.co',
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_prøve',
}

const KONVOLUTT = {
  eventId: '4a1d0f2e-9c33-4b71-8f5a-2b6c7d8e9f01',
  accessToken: 'brukerens-egen-token',
  area: 'work_queue',
  kind: 'unavailable',
  operation: 'public_work_board',
  code: null,
  httpStatus: null,
  transport: 'network',
  detail: 'TypeError: Failed to fetch\n    at callRpc (gateway.ts:1:1)',
}

function post(body: unknown): Request {
  return new Request('https://antidep.example/diagnostics', {
    method: 'POST',
    body: typeof body === 'string' ? body : JSON.stringify(body),
  })
}

describe('lesingen av konvolutten', () => {
  it('leser en konvolutt som den står', () => {
    expect(parseDiagnosticEnvelope(KONVOLUTT).detail).toContain('Failed to fetch')
  })

  it.each([
    ['et ukjent område', { ...KONVOLUTT, area: 'noe annet' }],
    ['en ukjent svikttype', { ...KONVOLUTT, kind: 'not_authorized' }],
    ['en ukjent transportform', { ...KONVOLUTT, transport: 'kanskje' }],
    ['en status som ikke er en status', { ...KONVOLUTT, httpStatus: 9000 }],
    ['ingen token', { ...KONVOLUTT, accessToken: '' }],
    ['et nummer som ikke er en uuid', { ...KONVOLUTT, eventId: 'nummer 1' }],
  ])('avviser %s', (_hva, verdi) => {
    expect(() => parseDiagnosticEnvelope(verdi)).toThrow(/ugyldig/)
  })

  it('klipper en absurd lang årsak', () => {
    expect(
      parseDiagnosticEnvelope({ ...KONVOLUTT, detail: 'x'.repeat(50000) }).detail,
    ).toHaveLength(4000)
  })
})

describe('ruten', () => {
  it('videresender brukerens egen token, og ingen av sine egne', async () => {
    const sendt: { target: ForwardTarget; args: Record<string, unknown> }[] = []
    const forward: ForwardDiagnostic = (target, args) => {
      sendt.push({ target, args })
      return Promise.resolve({ delivered: true, retry: false })
    }

    const response = await serveDiagnostics(post(KONVOLUTT), MILJØ, forward)

    expect(response.status).toBe(204)
    expect(sendt).toHaveLength(1)
    expect(sendt[0]?.target.url).toBe('https://prosjekt.supabase.co')
    expect(sendt[0]?.target.accessToken).toBe('brukerens-egen-token')
    expect(sendt[0]?.target.publishableKey).toBe('sb_publishable_prøve')
    expect(sendt[0]?.args).toMatchObject({
      p_event_id: '4a1d0f2e-9c33-4b71-8f5a-2b6c7d8e9f01',
      p_area: 'work_queue',
      p_operation: 'public_work_board',
      p_transport: 'network',
    })
    expect(String(sendt[0]?.args.p_detail)).toContain('Failed to fetch')
  })

  // Det ene en server kan gjøre som en nettleser midt i en navigasjon ikke kan.
  it('prøver igjen når transporten sviktet uten at databasen svarte', async () => {
    let forsøk = 0
    const forward: ForwardDiagnostic = () => {
      forsøk += 1
      return Promise.resolve({ delivered: false, retry: true })
    }
    await serveDiagnostics(post(KONVOLUTT), MILJØ, forward)
    expect(forsøk).toBe(2)
  })

  it('prøver ikke igjen på en avvisning, som er databasens avgjørelse', async () => {
    let forsøk = 0
    const forward: ForwardDiagnostic = () => {
      forsøk += 1
      return Promise.resolve({ delivered: false, retry: false })
    }
    await serveDiagnostics(post(KONVOLUTT), MILJØ, forward)
    expect(forsøk).toBe(1)
  })

  it('kaster aldri, heller ikke når nettet mellom ruten og databasen ryker', async () => {
    const forward: ForwardDiagnostic = () => Promise.reject(new Error('ECONNRESET'))
    await expect(serveDiagnostics(post(KONVOLUTT), MILJØ, forward)).resolves.toMatchObject({
      status: 204,
    })
  })

  // Svaret skal ikke være et sted å prøve seg fram fra utsiden: det sier aldri
  // om tokenen var gyldig, eller om kvoten var brukt opp.
  it('svarer det samme enten databasen tok imot eller avviste', async () => {
    const tok = await serveDiagnostics(post(KONVOLUTT), MILJØ, () =>
      Promise.resolve({ delivered: true, retry: false }),
    )
    const avviste = await serveDiagnostics(post(KONVOLUTT), MILJØ, () =>
      Promise.resolve({ delivered: false, retry: false }),
    )
    expect(tok.status).toBe(avviste.status)
  })

  it.each([
    ['en kropp som ikke er JSON', 'ikke json', 400],
    ['en konvolutt som ikke stemmer', JSON.stringify({ area: 'work_queue' }), 400],
  ])('avviser %s uten å si hvorfor', async (_hva, body, status) => {
    const response = await serveDiagnostics(post(body), MILJØ, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(status)
  })

  it('avviser en kropp som er absurd stor, uten å lese den videre', async () => {
    const response = await serveDiagnostics(post('x'.repeat(20000)), MILJØ, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(413)
  })

  it('tar bare imot POST', async () => {
    const response = await serveDiagnostics(
      new Request('https://antidep.example/diagnostics'),
      MILJØ,
      () => {
        throw new Error('skal ikke videresendes')
      },
    )
    expect(response.status).toBe(405)
  })

  it('svarer 503 framfor å kaste når utrullingen mangler oppsett', async () => {
    const response = await serveDiagnostics(post(KONVOLUTT), {}, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(503)
  })
})
