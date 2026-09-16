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
import {
  serveDiagnostics,
  type DiagnosticsJournal,
  type ForwardDiagnostic,
  type ForwardTarget,
  type JournalLine,
} from './route.ts'

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

/** Serverloggen, lest av prøven i stedet for av utrullingen. */
function fangLoggen(): { linjer: JournalLine[]; journal: DiagnosticsJournal } {
  const linjer: JournalLine[] = []
  return { linjer, journal: (line) => linjer.push(line) }
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
  // Databasen vasker uansett, men teksten skal ikke gå videre uvasket fra en
  // kaller ruten ikke kontrollerer.
  it('vasker tokenformede strenger før den sender videre', async () => {
    const sendt: { args: Record<string, unknown> }[] = []
    const forward: ForwardDiagnostic = (_target, args) => {
      sendt.push({ args })
      return Promise.resolve({ delivered: true, retry: false })
    }
    await serveDiagnostics(
      post({
        ...KONVOLUTT,
        detail: 'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur',
      }),
      MILJØ,
      forward,
    )
    expect(String(sendt[0]?.args.p_detail)).not.toContain('hemmelig.signatur')
  })

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

  // Dette er forskjellen som gjør utboksen verdt noe: en lagring som ikke gikk
  // gjennom, må ikke se ut som en bekreftet levering. Ellers sletter
  // nettleseren årsaken den nettopp skulle berge.
  it('sier fra når observasjonen ikke ble lagret, så nettleseren beholder den', async () => {
    const ryker: ForwardDiagnostic = () => Promise.reject(new Error('ECONNRESET'))
    await expect(serveDiagnostics(post(KONVOLUTT), MILJØ, ryker)).resolves.toMatchObject({
      status: 503,
    })

    const svarteIkke: ForwardDiagnostic = () => Promise.resolve({ delivered: false, retry: true })
    await expect(serveDiagnostics(post(KONVOLUTT), MILJØ, svarteIkke)).resolves.toMatchObject({
      status: 503,
    })
  })

  // Utover det ene skillet skal svaret ikke være et sted å prøve seg fram fra
  // utsiden: det sier aldri om tokenen var gyldig, eller om kvoten var brukt
  // opp. Begge er endelige svar fra databasen, og begge er 204.
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
    const logg = fangLoggen()
    const response = await serveDiagnostics(
      post(KONVOLUTT),
      {},
      () => {
        throw new Error('skal ikke videresendes')
      },
      logg.journal,
    )
    expect(response.status).toBe(503)
    // Uten oppsett finnes ingen rad, og loggen er alt som er igjen.
    expect(logg.linjer.at(-1)?.bareILoggen).toBe(true)
  })
})

// ============================================================================
// Serverloggen
//
// Raden nås over Data API-et, og et Data API som er nede er nettopp det den rå
// årsaken skal forklare. Linjen skrives derfor på Antideps egen opprinnelse,
// uten å gå gjennom Supabase i det hele tatt — og den skrives først, slik at
// den finnes selv om prosessen blir revet ned i kallet videre.
// ============================================================================
describe('serverloggen', () => {
  it('skriver observasjonen før den prøver databasen', async () => {
    const logg = fangLoggen()
    let skrevetFørKallet = false
    const forward: ForwardDiagnostic = () => {
      skrevetFørKallet = logg.linjer.length === 1
      return Promise.resolve({ delivered: true, retry: false })
    }
    await serveDiagnostics(post(KONVOLUTT), MILJØ, forward, logg.journal)
    expect(skrevetFørKallet).toBe(true)
    expect(logg.linjer[0]).toMatchObject({
      event: '4a1d0f2e-9c33-4b71-8f5a-2b6c7d8e9f01',
      reporter: 'innlogget',
      area: 'work_queue',
      operation: 'public_work_board',
    })
    expect(logg.linjer[0]?.detail).toContain('Failed to fetch')
  })

  // Tokenen er avsenderens legitimasjon og har ingenting i en logg å gjøre.
  it('bærer aldri tokenen, og aldri hvem avsenderen var', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(JSON.stringify(logg.linjer)).not.toContain('brukerens-egen-token')
  })

  it('vasker teksten før den skrives ned', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post({
        ...KONVOLUTT,
        detail: 'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur',
      }),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(logg.linjer[0]?.detail).not.toContain('hemmelig.signatur')
  })

  // Dette er hele grunnen til at loggen finnes: raden kom ikke fram, og den som
  // leter skal kunne se nøyaktig hvilke observasjoner som bare ligger her.
  it('merker linjen når raden ikke kom fram', async () => {
    const logg = fangLoggen()
    const response = await serveDiagnostics(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
    )
    expect(response.status).toBe(503)
    expect(logg.linjer).toHaveLength(2)
    expect(logg.linjer[0]?.bareILoggen).toBeUndefined()
    expect(logg.linjer[1]?.bareILoggen).toBe(true)
  })

  it('merker den ikke når raden kom fram', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]?.bareILoggen).toBeUndefined()
  })
})

// ============================================================================
// Den uinnloggede besøkende
//
// Arbeidsoversikten er offentlig. Svikter den for noen som ikke er innlogget,
// finnes det ingen å tilskrive en rad — men årsaken er like verdt å forstå.
// Observasjonen tas imot og skrives bare i serverloggen.
// ============================================================================
describe('en anonym observasjon', () => {
  const ANONYM = { ...KONVOLUTT, accessToken: null }

  it('tas imot og skrives i loggen, men aldri i databasen', async () => {
    const logg = fangLoggen()
    const response = await serveDiagnostics(
      post(ANONYM),
      MILJØ,
      () => {
        throw new Error('en anonym observasjon skal aldri nå databasen')
      },
      logg.journal,
    )
    expect(response.status).toBe(204)
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]?.reporter).toBe('anonym')
    expect(logg.linjer[0]?.detail).toContain('Failed to fetch')
  })

  // Veien inn er så smal som den kan bli: de tre andre områdene finnes bare bak
  // innlogging, så en anonym melding om dem beskriver noe avsenderen ikke kan
  // ha sett.
  it.each(['automatic_task', 'agent_service', 'full_text_intake'])(
    'skriver ingenting ned om %s, som en uinnlogget ikke kan se',
    async (område) => {
      const logg = fangLoggen()
      const response = await serveDiagnostics(
        post({ ...ANONYM, area: område }),
        MILJØ,
        () => {
          throw new Error('skal ikke videresendes')
        },
        logg.journal,
      )
      // Svaret skiller seg ikke ut: ruten er ikke et sted å kartlegge noe fra.
      expect(response.status).toBe(204)
      expect(logg.linjer).toHaveLength(0)
    },
  )

  it.each(['work_queue', 'clinical_content'])('tar imot %s, som er offentlig', async (område) => {
    const logg = fangLoggen()
    const response = await serveDiagnostics(
      post({ ...ANONYM, area: område }),
      MILJØ,
      () => {
        throw new Error('skal ikke videresendes')
      },
      logg.journal,
    )
    expect(response.status).toBe(204)
    expect(logg.linjer).toHaveLength(1)
  })

  // Den kan ikke følges opp med den som sendte den, og den blir aldri en rad.
  // Da er en kortere utgave nesten like mye verdt, og den åpne veien inn
  // tilsvarende mindre verdt å misbruke.
  it('klippes kortere enn en innlogget observasjon', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post({ ...ANONYM, detail: 'x'.repeat(4000) }),
      MILJØ,
      () => {
        throw new Error('skal ikke videresendes')
      },
      logg.journal,
    )
    expect(logg.linjer[0]?.detail).toHaveLength(1000)

    const innlogget = fangLoggen()
    await serveDiagnostics(
      post({ ...KONVOLUTT, detail: 'x'.repeat(4000) }),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      innlogget.journal,
    )
    expect(innlogget.linjer[0]?.detail).toHaveLength(4000)
  })

  // En tom token er ikke det samme som ingen token: den er en påstand om en
  // innlogging, og den skal fortsatt avvises.
  it('er ikke det samme som en tom token', () => {
    expect(() => parseDiagnosticEnvelope({ ...KONVOLUTT, accessToken: '' })).toThrow(/ugyldig/)
  })
})
