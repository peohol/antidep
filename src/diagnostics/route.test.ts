// ============================================================================
// Diagnostikkruten, prøvd mot det den faktisk skal tåle
//
// Ruten finnes fordi den rå årsaken ikke kan gå den samme veien som kallet som
// nettopp sviktet. Prøvene her handler derfor mest om hva som skjer når noe går
// galt: en kropp som ikke stemmer, et miljø som mangler, en database som svarer
// 503. I alle tilfeller skal ruten være taus utad og aldri kaste.
// ============================================================================

import { beforeEach, describe, expect, it } from 'vitest'

import { parseDiagnosticEnvelope } from './envelope.ts'
import {
  forgetAttempts,
  isAvailabilityCode,
  reporterIpHash,
  serveDiagnostics,
  type DiagnosticsJournal,
  type ForwardDiagnostic,
  type ForwardTarget,
  type JournalLine,
  type VerifyReporter,
} from './route.ts'
import type { DiagnosticsStore, StoredDiagnostic, StoredPublicProblem } from './store.ts'

const MILJØ = {
  ANTIDEP_SUPABASE_URL: 'https://prosjekt.supabase.co',
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_prøve',
}

const KONVOLUTT = {
  eventId: '4a1d0f2e-9c33-4b71-8f5a-2b6c7d8e9f01',
  accessToken: 'brukerens.egen.token',
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

/**
 * Avsenderen er kontrollert.
 *
 * Prøvene under handler om hva som skjer *etter* kontrollen. At den faktisk
 * finner sted, og hva som skjer når den sier nei, står i sin egen del nederst.
 */
const GODKJENT: VerifyReporter = () => Promise.resolve('verified')

/** Den vanlige veien gjennom ruten, med en avsender som er kontrollert. */
function svar(
  request: Request,
  env: Parameters<typeof serveDiagnostics>[1],
  forward?: ForwardDiagnostic,
  journal?: DiagnosticsJournal,
  store?: Parameters<typeof serveDiagnostics>[4],
): Promise<Response> {
  return serveDiagnostics(request, env, forward, journal, store ?? null, GODKJENT)
}

// Forsøksbudsjettet lever i minnet og deles av hele filen. Uten dette ville
// prøve nummer tretti-én fra den samme adressen blitt dempet, og feilet av en
// grunn som ikke hadde noe med den å gjøre.
beforeEach(forgetAttempts)

/** Adressen plattformen setter. Uten den kan serveren ikke telle avsenderen. */
const AVSENDER = { 'x-real-ip': '198.51.100.7' }

/**
 * Den varige lagringen, uten en database.
 *
 * `budsjett` er den felles forsøksgrensen: `true` slipper gjennom, `false` er
 * over grensen, og `null` er at databasen ikke svarte på spørsmålet.
 */
function fangLagringen(
  svar = true,
  budsjett: boolean | null = true,
): {
  beholdt: StoredDiagnostic[]
  meldt: StoredPublicProblem[]
  talt: string[]
  store: DiagnosticsStore
} {
  const beholdt: StoredDiagnostic[] = []
  const meldt: StoredPublicProblem[] = []
  const talt: string[] = []
  return {
    beholdt,
    meldt,
    talt,
    store: {
      keep: (entry) => {
        beholdt.push(entry)
        return Promise.resolve(svar)
      },
      keepPublicProblem: (entry) => {
        meldt.push(entry)
        return Promise.resolve(svar)
      },
      claimAttempt: (reporterIpHash) => {
        talt.push(reporterIpHash)
        return Promise.resolve(budsjett)
      },
    },
  }
}

/**
 * Den felles grensen slik databasen håndhever den: én teller, delt av alle
 * instansene, uansett hvor mange av dem som starter opp med friskt minne.
 */
function fellesGrense(tak = 30): { store: DiagnosticsStore; talt: Map<string, number> } {
  const talt = new Map<string, number>()
  const lagring = fangLagringen()
  return {
    talt,
    store: {
      ...lagring.store,
      claimAttempt: (reporterIpHash) => {
        const nå = (talt.get(reporterIpHash) ?? 0) + 1
        talt.set(reporterIpHash, nå)
        return Promise.resolve(nå <= tak)
      },
    },
  }
}

function post(body: unknown, headers: Record<string, string> = AVSENDER): Request {
  return new Request('https://antidep.example/diagnostics', {
    headers,
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
    await svar(
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

    const response = await svar(post(KONVOLUTT), MILJØ, forward)

    expect(response.status).toBe(204)
    expect(sendt).toHaveLength(1)
    expect(sendt[0]?.target.url).toBe('https://prosjekt.supabase.co')
    expect(sendt[0]?.target.accessToken).toBe('brukerens.egen.token')
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
    await svar(post(KONVOLUTT), MILJØ, forward)
    expect(forsøk).toBe(2)
  })

  it('prøver ikke igjen på en avvisning, som er databasens avgjørelse', async () => {
    let forsøk = 0
    const forward: ForwardDiagnostic = () => {
      forsøk += 1
      return Promise.resolve({ delivered: false, retry: false })
    }
    await svar(post(KONVOLUTT), MILJØ, forward)
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
    const tok = await svar(post(KONVOLUTT), MILJØ, () =>
      Promise.resolve({ delivered: true, retry: false }),
    )
    const avviste = await svar(post(KONVOLUTT), MILJØ, () =>
      Promise.resolve({ delivered: false, retry: false }),
    )
    expect(tok.status).toBe(avviste.status)
  })

  it.each([
    ['en kropp som ikke er JSON', 'ikke json', 400],
    ['en konvolutt som ikke stemmer', JSON.stringify({ area: 'work_queue' }), 400],
  ])('avviser %s uten å si hvorfor', async (_hva, body, status) => {
    const response = await svar(post(body), MILJØ, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(status)
  })

  it('avviser en kropp som er absurd stor, uten å lese den videre', async () => {
    const response = await svar(post('x'.repeat(20000)), MILJØ, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(413)
  })

  it('tar bare imot POST', async () => {
    const response = await svar(new Request('https://antidep.example/diagnostics'), MILJØ, () => {
      throw new Error('skal ikke videresendes')
    })
    expect(response.status).toBe(405)
  })

  it('svarer 503 framfor å kaste når utrullingen mangler oppsett', async () => {
    const logg = fangLoggen()
    const response = await svar(
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
  // Linjen skrives når databasen har bekreftet at avsenderen er ekte, og ikke
  // før. En tekst fra en ukontrollert avsender skal ikke stå i kjøreloggen — og
  // skulle prosessen dø før bekreftelsen, holder nettleseren fortsatt på
  // observasjonen, for den har ikke fått noe svar.
  it('skriver observasjonen når databasen har tatt imot den', async () => {
    const logg = fangLoggen()
    let skrevetFørKallet = 0
    const forward: ForwardDiagnostic = () => {
      skrevetFørKallet = logg.linjer.length
      return Promise.resolve({ delivered: true, retry: false })
    }
    await svar(post(KONVOLUTT), MILJØ, forward, logg.journal)

    expect(skrevetFørKallet).toBe(0)
    expect(logg.linjer).toHaveLength(1)
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
    await svar(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(JSON.stringify(logg.linjer)).not.toContain('brukerens.egen.token')
  })

  it('vasker teksten før den skrives ned', async () => {
    const logg = fangLoggen()
    await svar(
      post({
        ...KONVOLUTT,
        detail: 'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur',
      }),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(JSON.stringify(logg.linjer)).not.toContain('hemmelig.signatur')
  })

  // Dette er hele grunnen til at loggen finnes: raden kom ikke fram, og den som
  // leter skal kunne se nøyaktig hvilke observasjoner som bare ligger her.
  it('merker linjen når raden ikke kom fram', async () => {
    const logg = fangLoggen()
    const response = await svar(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
      // Reserven finnes, men tar heller ikke imot. Da er loggen det eneste
      // stedet observasjonen er, og linjen skal si det.
      fangLagringen(false).store,
    )
    expect(response.status).toBe(503)
    expect(logg.linjer).toHaveLength(2)
    expect(logg.linjer.filter((linje) => linje.bareILoggen === true)).toHaveLength(1)
    expect(logg.linjer.at(-1)?.bareILoggen).toBe(true)
    expect(logg.linjer.at(-1)?.detail).toContain('Failed to fetch')
  })

  it('merker den ikke når raden kom fram', async () => {
    const logg = fangLoggen()
    await svar(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
    )
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer.some((linje) => linje.bareILoggen === true)).toBe(false)
  })
})

// ============================================================================
// Den uinnloggede besøkende
//
// Arbeidsoversikten er offentlig. Svikter den for noen som ikke er innlogget,
// finnes det ingen å tilskrive noe — og en åpen vei inn for tekst ville vært en
// logg hvem som helst kunne fylle med sine egne ord. Meldingen bærer derfor
// maskinidentifikatorer og ikke ett tegn av kallerens egen tekst.
// ============================================================================
describe('en anonym observasjon', () => {
  const ANONYM = { ...KONVOLUTT, accessToken: null }

  it('melder problemet uten å nå den vanlige skriveveien', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await svar(
      post(ANONYM),
      MILJØ,
      () => {
        throw new Error('en anonym melding skal aldri gå over Data API-et')
      },
      logg.journal,
      lagring.store,
    )
    expect(response.status).toBe(204)
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]?.reporter).toBe('anonym')
    expect(lagring.meldt).toHaveLength(1)
    expect(lagring.meldt[0]).toMatchObject({ area: 'work_queue', operation: 'public_work_board' })
    // Den andre veien røres ikke: en anonym melding blir aldri en rå-årsak-rad.
    expect(lagring.beholdt).toHaveLength(0)
  })

  // Dette er hele grensen. Kalleren legger ved tekst, og ingenting av den skal
  // finnes noe sted etterpå — verken i loggen eller på vei mot databasen.
  it('tar ikke med ett tegn av kallerens tekst, uansett hva som lå ved', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    await svar(
      post({ ...ANONYM, detail: 'HEMMELIG-PÅFØRT-TEKST fra en fremmed' }),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
      lagring.store,
    )
    const alt = JSON.stringify({ linjer: logg.linjer, ...lagring })
    expect(alt).not.toContain('HEMMELIG-PÅFØRT-TEKST')
    expect(logg.linjer[0]?.detail).toBe('(ingen tekst: meldingen kom fra en uinnlogget besøkende)')
  })

  // Konvolutten kaster teksten allerede før ruten ser den. Beltet i tillegg
  // til selene: to uavhengige grenser, og begge må svikte for at en fremmeds
  // ord skal kunne nå noe som helst.
  it('kaster teksten allerede i konvolutten', () => {
    const lest = parseDiagnosticEnvelope({ ...ANONYM, detail: 'HEMMELIG-PÅFØRT-TEKST' })
    expect(lest.detail).toBe('')
  })

  // Veien inn er så smal som den kan bli: de tre andre områdene finnes bare bak
  // innlogging, så en anonym melding om dem beskriver noe avsenderen ikke kan
  // ha sett.
  it.each(['automatic_task', 'agent_service', 'full_text_intake'])(
    'skriver ingenting ned om %s, som en uinnlogget ikke kan se',
    async (område) => {
      const logg = fangLoggen()
      const lagring = fangLagringen()
      const response = await svar(
        post({ ...ANONYM, area: område }),
        MILJØ,
        () => {
          throw new Error('skal ikke videresendes')
        },
        logg.journal,
        lagring.store,
      )
      // Svaret skiller seg ikke ut: ruten er ikke et sted å kartlegge noe fra.
      expect(response.status).toBe(204)
      expect(logg.linjer).toHaveLength(0)
      expect(lagring.meldt).toHaveLength(0)
    },
  )

  it.each(['work_queue', 'clinical_content'])('tar imot %s, som er offentlig', async (område) => {
    const lagring = fangLagringen()
    const response = await svar(
      post({ ...ANONYM, area: område }),
      MILJØ,
      () => {
        throw new Error('skal ikke videresendes')
      },
      fangLoggen().journal,
      lagring.store,
    )
    expect(response.status).toBe(204)
    expect(lagring.meldt).toHaveLength(1)
  })

  // En avsender vi ikke kan telle, kan vi heller ikke begrense. Da skrives
  // ingenting, framfor å åpne en vei uten grense.
  it('skriver ingenting når serveren ikke kjenner avsenderen', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await svar(
      post(ANONYM, {}),
      MILJØ,
      () => {
        throw new Error('skal ikke videresendes')
      },
      logg.journal,
      lagring.store,
    )
    expect(response.status).toBe(204)
    expect(logg.linjer).toHaveLength(0)
    expect(lagring.meldt).toHaveLength(0)
  })

  // En tom token er ikke det samme som ingen token: den er en påstand om en
  // innlogging, og den skal fortsatt avvises.
  it('er ikke det samme som en tom token', () => {
    expect(() => parseDiagnosticEnvelope({ ...KONVOLUTT, accessToken: '' })).toThrow(/ugyldig/)
  })
})

// ============================================================================
// Reserven som ikke går gjennom Data API-et
//
// Dette er selve grunnen til at ruten har en egen databaseforbindelse: raden
// skal komme fram også når PostgREST ikke svarer. Prøvene her er på nøyaktig
// det skillet.
// ============================================================================
describe('reserveveien', () => {
  const nede: ForwardDiagnostic = () => Promise.resolve({ delivered: false, retry: true })

  it('lagrer raden når Data API-et ikke tok imot', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await svar(post(KONVOLUTT), MILJØ, nede, logg.journal, lagring.store)

    expect(response.status).toBe(204)
    expect(lagring.beholdt).toHaveLength(1)
    expect(lagring.beholdt[0]?.detail).toContain('Failed to fetch')
    expect(lagring.beholdt[0]?.eventId).toBe('4a1d0f2e-9c33-4b71-8f5a-2b6c7d8e9f01')
    // Raden kom fram, så linjen skal ikke si at loggen er alt som finnes.
    expect(logg.linjer.some((linje) => linje.bareILoggen === true)).toBe(false)
  })

  // Normalveien er fortsatt Data API-et. Reserven skal ikke brukes når den
  // første virker — ellers ville hver observasjon blitt to rader.
  it('røres ikke når Data API-et tok imot', async () => {
    const lagring = fangLagringen()
    await svar(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      fangLoggen().journal,
      lagring.store,
    )
    expect(lagring.beholdt).toHaveLength(0)
  })

  // En avvisning er databasens egen avgjørelse, og den gjelder begge veier.
  it('røres ikke når databasen avviste observasjonen', async () => {
    const lagring = fangLagringen()
    await svar(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: false }),
      fangLoggen().journal,
      lagring.store,
    )
    expect(lagring.beholdt).toHaveLength(0)
  })

  it('bærer avsendersummen, og aldri adressen selv', async () => {
    const lagring = fangLagringen()
    await svar(post(KONVOLUTT), MILJØ, nede, fangLoggen().journal, lagring.store)
    expect(lagring.beholdt[0]?.reporterIpHash).toMatch(/^[0-9a-f]{64}$/)
    expect(JSON.stringify(lagring.beholdt)).not.toContain('198.51.100.7')
  })

  it('sier fra når heller ikke reserven tok imot', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen(false)
    const response = await svar(post(KONVOLUTT), MILJØ, nede, logg.journal, lagring.store)

    expect(response.status).toBe(503)
    expect(logg.linjer.at(-1)?.bareILoggen).toBe(true)
  })

  it('sier fra når utrullingen ikke har fått legitimasjonen', async () => {
    const logg = fangLoggen()
    const response = await svar(post(KONVOLUTT), MILJØ, nede, logg.journal, null)

    expect(response.status).toBe(503)
    expect(logg.linjer.at(-1)?.bareILoggen).toBe(true)
  })

  // Uten Data API-adresse finnes ingen autentiseringstjeneste heller, og da kan
  // ingen bekrefte hvem avsenderen er. Da skrives ingen tekst noe sted — heller
  // ikke i reserven — og nettleseren beholder årsaken.
  it('brukes ikke når ingen kan bekrefte hvem avsenderen er', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await svar(
      post(KONVOLUTT),
      {},
      () => {
        throw new Error('skal ikke videresendes uten adresse')
      },
      logg.journal,
      lagring.store,
    )
    expect(response.status).toBe(503)
    expect(lagring.beholdt).toHaveLength(0)
    expect(JSON.stringify(logg.linjer)).not.toContain('Failed to fetch')
  })

  // Dette er punkt 3 fra tiende gjennomgang: PostgRESTs egne connection-feil
  // *har* kode, og ble derfor lest som endelige avvisninger. Da ble reserven
  // hoppet over i nøyaktig de tilfellene den finnes for.
  it.each(['PGRST000', 'PGRST001', 'PGRST002', 'PGRST003', '08006', '53300', '57P01', '40001'])(
    'brukes når Data API-et svarer %s, som er utilgjengelighet og ikke en avvisning',
    (kode) => {
      expect(isAvailabilityCode(kode)).toBe(true)
    },
  )

  it.each(['42501', '23505', 'PGRST301', 'PGRST116', '22023'])(
    'brukes ikke når databasen svarer %s, som er dens egen avgjørelse',
    (kode) => {
      expect(isAvailabilityCode(kode)).toBe(false)
    },
  )
})

// ============================================================================
// Kontrollen av avsenderen
//
// En påstand om å være innlogget er ikke en innlogging. Uten denne kontrollen
// kunne hvem som helst sende en ikke-tom token og fritt valgt tekst, og få den
// skrevet ned som om den kom fra en bruker — og videre inn i reserven dersom
// Data API-et samtidig var nede.
// ============================================================================
describe('avsenderen må være kontrollert før teksten brukes', () => {
  const PÅFØRT = {
    ...KONVOLUTT,
    accessToken: 'paastatt.men-ikke.ekte',
    detail: 'HEMMELIG-PÅFØRT-TEKST fra en fremmed',
  }

  it('skriver ingen tekst når kontrollen sier nei', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => {
        throw new Error('en ukontrollert avsender skal aldri nå databasen')
      },
      logg.journal,
      lagring.store,
      () => Promise.resolve('rejected'),
    )

    // Svaret skiller seg ikke ut: ruten er ikke et sted å prøve seg fram fra.
    expect(response.status).toBe(204)
    expect(JSON.stringify({ linjer: logg.linjer, ...lagring })).not.toContain(
      'HEMMELIG-PÅFØRT-TEKST',
    )
    expect(lagring.beholdt).toHaveLength(0)
  })

  // Og det farlige tilfellet: Data API-et er nede, så reserven ville vært i
  // bruk. Uten kontrollen ville den fremmede teksten blitt varig lagret.
  it('skriver ingen tekst når ingen kan bekrefte avsenderen', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen()
    const response = await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
      lagring.store,
      () => Promise.resolve('unknown'),
    )

    expect(response.status).toBe(503)
    expect(lagring.beholdt).toHaveLength(0)
    expect(JSON.stringify({ linjer: logg.linjer, ...lagring })).not.toContain(
      'HEMMELIG-PÅFØRT-TEKST',
    )
  })

  // En avsender som ikke er den den utgir seg for, skal ikke etterlate seg noe
  // i det hele tatt — heller ikke en linje som sier at den prøvde. Og den som
  // avviser, er databasen selv: `auth.uid()` er null, og svaret er 42501.
  it('skriver ingenting når databasen sier nei', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: false }),
      logg.journal,
      null,
      () => {
        throw new Error('autentiseringstjenesten skal ikke spørres når databasen svarte')
      },
    )
    expect(logg.linjer).toHaveLength(0)
  })

  // Og det som gjør hele flaten billig: så lenge Data API-et svarer, spørres
  // autentiseringstjenesten aldri — hverken på et ja eller et nei. En
  // utenforstående kan ikke utløse den grenen, for den krever at Data API-et
  // faktisk er nede.
  it('spør ikke autentiseringstjenesten når Data API-et svarer', async () => {
    let spurt = 0
    const tell: VerifyReporter = () => {
      spurt += 1
      return Promise.resolve('verified')
    }
    await serveDiagnostics(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      () => undefined,
      null,
      tell,
    )
    await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: false }),
      () => undefined,
      null,
      tell,
    )
    expect(spurt).toBe(0)
  })

  // Men når ingen *kunne* svare, er det en opplysning verdt å ha: da er det
  // Antidep som ikke virker, ikke avsenderen som lyver.
  it('skriver maskinidentifikatorene når ingen kunne svare, og aldri teksten', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
      null,
      () => Promise.resolve('unknown'),
    )
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]).toMatchObject({
      reporter: 'ukjent',
      area: 'work_queue',
      operation: 'public_work_board',
      detail: '(ingen tekst: avsenderen er ikke kontrollert ennå)',
      bareILoggen: true,
    })
  })

  // Formkontrollen står før Auth-kallet: et kall som uansett ikke kan lykkes,
  // skal ikke koste en rundtur til autentiseringstjenesten.
  it.each(['x', 'bare.to', 'fire.ledd.er.for.mange', 'ikke en token'])(
    'spør ikke autentiseringstjenesten om «%s», som ikke er en token',
    async (påstand) => {
      const logg = fangLoggen()
      let spurt = 0
      const response = await serveDiagnostics(
        post({ ...KONVOLUTT, accessToken: påstand }),
        MILJØ,
        () => {
          throw new Error('skal ikke videresendes')
        },
        logg.journal,
        null,
        () => {
          spurt += 1
          return Promise.resolve('verified')
        },
      )
      expect(response.status).toBe(204)
      expect(spurt).toBe(0)
      expect(logg.linjer).toHaveLength(0)
    },
  )

  // Demperen i denne instansen: den sparer et kall til databasen når svaret
  // allerede er kjent her.
  it('demper en avsender som prøver om og om igjen', async () => {
    const lagring = fangLagringen()
    let spurt = 0
    const tell: VerifyReporter = () => {
      spurt += 1
      return Promise.resolve('rejected')
    }
    for (let i = 0; i < 40; i += 1) {
      await serveDiagnostics(
        post(PÅFØRT),
        MILJØ,
        // Data API-et er nede. Det er den eneste grenen der
        // autentiseringstjenesten spørres i det hele tatt.
        () => Promise.resolve({ delivered: false, retry: true }),
        () => undefined,
        lagring.store,
        tell,
      )
    }
    // Tretti i minuttet, og ikke førti rundturer til autentiseringstjenesten.
    expect(spurt).toBe(30)
    // Og databasen ble heller ikke spurt de siste ti gangene.
    expect(lagring.talt).toHaveLength(30)
  })

  // Punkt 2 fra tolvte gjennomgang, og det som gjør grensen til et vern framfor
  // en demper: en serverless flate har mange instanser, og hver av dem starter
  // med friskt minne. `forgetAttempts()` er nettopp den kalde instansen — uten
  // en felles teller ville hver runde her fått sitt eget budsjett.
  it('gir ikke et friskt budsjett til hver nye instans', async () => {
    const felles = fellesGrense()
    let spurt = 0
    const tell: VerifyReporter = () => {
      spurt += 1
      return Promise.resolve('rejected')
    }
    for (let i = 0; i < 40; i += 1) {
      // Hver runde er en ny instans, med et tomt minne.
      forgetAttempts()
      await serveDiagnostics(
        post(PÅFØRT),
        MILJØ,
        () => Promise.resolve({ delivered: false, retry: true }),
        () => undefined,
        felles.store,
        tell,
      )
    }
    expect(felles.talt.get(reporterIpHash(post(PÅFØRT)) ?? '')).toBe(40)
    // Førti kalde instanser, og fortsatt tretti rundturer.
    expect(spurt).toBe(30)
  })

  // Og når den felles grensen sier nei, skjer ingenting mer: ingen rundtur og
  // ingen linje. Men svaret er 503 og ikke 204 — se prøven under.
  it('spør ikke autentiseringstjenesten når den felles grensen sier nei', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen(true, false)
    const response = await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
      lagring.store,
      () => {
        throw new Error('autentiseringstjenesten skal ikke spørres over grensen')
      },
    )
    expect(response.status).toBe(503)
    expect(logg.linjer).toHaveLength(0)
    expect(lagring.beholdt).toHaveLength(0)
  })

  // Punkt 2 fra trettende gjennomgang: et 204 her ville fått nettleseren til å
  // slette observasjonen fordi den trodde den var kommet fram — og den er ikke
  // lagret noe sted. Forskjellen på denne grensen og en kvote er at den er til
  // å vente ut: tretti i minuttet, og et forsøk om et øyeblikk lykkes.
  it('ber om et nytt forsøk framfor å kvittere når grensen er nådd', async () => {
    const lagring = fangLagringen()
    const svarene: number[] = []
    for (let i = 0; i < 31; i += 1) {
      const response = await serveDiagnostics(
        post(KONVOLUTT),
        MILJØ,
        () => Promise.resolve({ delivered: false, retry: true }),
        () => undefined,
        lagring.store,
        GODKJENT,
      )
      svarene.push(response.status)
    }
    // De tretti første kom gjennom grensen og ble lagret.
    expect(svarene.slice(0, 30)).toEqual(Array.from({ length: 30 }, () => 204))
    // Den trettiførste ble stoppet av den, og skal beholdes i utboksen.
    expect(svarene[30]).toBe(503)
    expect(lagring.beholdt).toHaveLength(30)
  })

  // Og svarer databasen ikke på spørsmålet heller, er det ikke avsenderen som
  // er over en grense — det er at ingen grense kan håndheves. Da skal ingenting
  // videre skje, og nettleseren skal beholde observasjonen.
  it('spør ingen når den felles grensen ikke kunne håndheves', async () => {
    const logg = fangLoggen()
    const lagring = fangLagringen(true, null)
    const response = await serveDiagnostics(
      post(PÅFØRT),
      MILJØ,
      () => Promise.resolve({ delivered: false, retry: true }),
      logg.journal,
      lagring.store,
      () => {
        throw new Error('autentiseringstjenesten skal ikke spørres uten en grense')
      },
    )
    expect(response.status).toBe(503)
    expect(logg.linjer.at(-1)?.bareILoggen).toBe(true)
    expect(JSON.stringify(logg.linjer)).not.toContain('HEMMELIG-PÅFØRT-TEKST')
    expect(lagring.beholdt).toHaveLength(0)
  })

  // Budsjettet er per avsender: én som prøver for mye, skal ikke stenge ute en
  // annen som bare møtte en feil.
  it('demper bare den avsenderen som prøver for mye', async () => {
    const lagring = fangLagringen()
    for (let i = 0; i < 40; i += 1) {
      await serveDiagnostics(
        post(PÅFØRT),
        MILJØ,
        () => Promise.resolve({ delivered: false, retry: true }),
        () => undefined,
        lagring.store,
        () => Promise.resolve('rejected'),
      )
    }

    const logg = fangLoggen()
    const response = await serveDiagnostics(
      post(KONVOLUTT, { 'x-real-ip': '203.0.113.9' }),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
      null,
      GODKJENT,
    )
    expect(response.status).toBe(204)
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]?.reporter).toBe('innlogget')
  })

  it('skriver teksten først etter at kontrollen har sagt ja', async () => {
    const logg = fangLoggen()
    await serveDiagnostics(
      post(KONVOLUTT),
      MILJØ,
      () => Promise.resolve({ delivered: true, retry: false }),
      logg.journal,
      null,
      GODKJENT,
    )
    expect(logg.linjer).toHaveLength(1)
    expect(logg.linjer[0]?.reporter).toBe('innlogget')
    expect(logg.linjer[0]?.detail).toContain('Failed to fetch')
  })

  // Kontrollen går til autentiseringstjenesten, og ikke til Data API-et. Det er
  // hele poenget: de kan være nede hver for seg.
  it('spør autentiseringstjenesten, med brukerens egen token', async () => {
    const spurt: { url: string; headers: Record<string, string> }[] = []
    const opprinnelig = globalThis.fetch
    globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
      spurt.push({
        url: String(input),
        headers: (init?.headers ?? {}) as Record<string, string>,
      })
      return Promise.resolve(new Response(null, { status: 401 }))
    }) as typeof fetch

    try {
      const response = await serveDiagnostics(
        post(KONVOLUTT),
        MILJØ,
        () => {
          throw new Error('skal ikke videresendes')
        },
        () => undefined,
        // Reserven må finnes, ellers er det ingenting å hente i en rundtur til
        // autentiseringstjenesten, og ruten gjør den ikke.
        fangLagringen().store,
      )
      expect(response.status).toBe(204)
    } finally {
      globalThis.fetch = opprinnelig
    }

    expect(spurt[0]?.url).toBe('https://prosjekt.supabase.co/auth/v1/user')
    expect(spurt[0]?.headers.authorization).toBe('Bearer brukerens.egen.token')
    expect(spurt[0]?.headers.apikey).toBe('sb_publishable_prøve')
  })
})

// ============================================================================
// Avsenderen serveren selv observerte
// ============================================================================
describe('avsendersummen', () => {
  const be = (headers: Record<string, string>): Request =>
    new Request('https://antidep.example/diagnostics', { method: 'POST', headers })

  it('leser plattformens eget hode framfor kallerens', () => {
    const plattform = reporterIpHash(be({ 'x-real-ip': '198.51.100.7' }))
    const påstått = reporterIpHash(
      be({ 'x-real-ip': '198.51.100.7', 'x-forwarded-for': '203.0.113.9' }),
    )
    expect(påstått).toBe(plattform)
  })

  it('roterer i døgnet, så summen ikke følger noen over tid', () => {
    const request = be({ 'x-real-ip': '198.51.100.7' })
    const mandag = reporterIpHash(request, new Date('2026-09-14T10:00:00Z'))
    const tirsdag = reporterIpHash(request, new Date('2026-09-15T10:00:00Z'))
    expect(mandag).not.toBe(tirsdag)
    expect(mandag).toMatch(/^[0-9a-f]{64}$/)
  })

  it('er ingenting når ingen adresse finnes', () => {
    expect(reporterIpHash(be({}))).toBeNull()
  })
})
