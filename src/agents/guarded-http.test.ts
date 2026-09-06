// Testene her starter en ekte HTTP-server på loopback og henter fra den.
//
// Det er med vilje: redirect-håndteringen, størrelsesgrensen og tidsavbruddet
// er alle egenskaper ved en faktisk forbindelse, og en dobbel av `http.request`
// ville prøvd doblingen framfor koden. Loopback er samtidig nøyaktig den
// adressen vakten skal avvise, så testene deler seg i to:
//
//   * standardvakten prøves mot loopback og skal avvise — uten noen overstyring,
//     slik en angriper ville møtt den;
//   * mekanikken prøves med en eksplisitt tillatende `addressPolicy`, som bare
//     kan settes fra en test.
//
// @vitest-environment node

import { createServer, type Server } from 'node:http'
import type { Socket } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { guardedGet, judgeResolvedAddresses } from './guarded-http'
import { judgeAddress } from './address-guard'

const ALLOW_ALL = () => ({ allowed: true })

let running: Server | null = null

afterEach(async () => {
  if (running !== null) {
    const server = running
    running = null
    // Rydding, ikke en forutsetning: koden river forbindelsene sine selv, og
    // testene over krever nettopp det. Dette finnes for at en test som feiler
    // midt i, ikke skal henge på `close()`.
    server.closeAllConnections()
    await new Promise<void>((resolve) => {
      server.close(() => {
        resolve()
      })
    })
  }
})

interface StartedServer {
  readonly origin: string
  /** Hvor mange socketer serveren har sett lukket. */
  readonly closedConnections: () => number
  readonly openConnections: () => number
}

async function startServer(handler: Parameters<typeof createServer>[1]): Promise<StartedServer> {
  const server = createServer(handler)
  running = server

  let opened = 0
  let closed = 0
  server.on('connection', (socket: Socket) => {
    opened += 1
    socket.on('close', () => {
      closed += 1
    })
  })

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve()
    })
  })
  const address = server.address()
  if (address === null || typeof address === 'string') {
    throw new Error('serveren fikk ingen port')
  }
  return {
    origin: `http://127.0.0.1:${String(address.port)}`,
    closedConnections: () => closed,
    openConnections: () => opened - closed,
  }
}

describe('guardedGet — adressevakten er på som standard', () => {
  // Kjernen i hele modulen: uten en eksplisitt overstyring skal en adresse på
  // loopback aldri nås, uansett at serveren svarer.
  it('avviser loopback uten at serveren blir kontaktet', async () => {
    let contacted = false
    const { origin } = await startServer((_request, response) => {
      contacted = true
      response.end('hemmelig')
    })

    const result = await guardedGet(origin)

    expect(result.status).toBe('error')
    expect(result).toMatchObject({
      message: expect.stringContaining('offentlig internettadresse') as unknown as string,
    })
    expect(contacted).toBe(false)
  })

  // Den andre halvdelen av vakten: et navn som slår opp til en privat adresse.
  // `localhost` er nettopp det — og den veien går gjennom `lookup`, ikke
  // gjennom kontrollen av en bokstavelig adresse.
  it('avviser et navn som slår opp til en privat adresse', async () => {
    let contacted = false
    const { origin } = await startServer((_request, response) => {
      contacted = true
      response.end('hemmelig')
    })
    const port = new URL(origin).port

    const result = await guardedGet(`http://localhost:${port}/`)

    expect(result.status).toBe('error')
    expect(result).toMatchObject({
      message: expect.stringContaining('offentlig internettadresse') as unknown as string,
    })
    expect(contacted).toBe(false)
  })
})

describe('judgeResolvedAddresses — regelen navneoppslaget bruker', () => {
  it('slipper gjennom når alle adressene er offentlige', () => {
    expect(
      judgeResolvedAddresses('eksempel.no', ['8.8.8.8', '2606:4700::1111'], judgeAddress),
    ).toBe(null)
  })

  // Et navn som peker både på en offentlig og en privat adresse, avvises i sin
  // helhet: å plukke den offentlige ville gjort utfallet avhengig av
  // rekkefølgen resolveren tilfeldigvis svarer i — og den rekkefølgen kan den
  // som eier navnet, styre.
  it('avviser når bare én av adressene er privat', () => {
    expect(judgeResolvedAddresses('eksempel.no', ['8.8.8.8', '10.0.0.5'], judgeAddress)).toContain(
      '10.0.0.5',
    )
  })

  it('avviser et navn som slår opp til skyens metadataadresse', () => {
    expect(judgeResolvedAddresses('eksempel.no', ['169.254.169.254'], judgeAddress)).toContain(
      'metadatatjeneste',
    )
  })

  it('avviser et navn uten adresser', () => {
    expect(judgeResolvedAddresses('eksempel.no', [], judgeAddress)).toContain(
      'ikke opp til noen adresse',
    )
  })

  it('avviser en adresse som ikke er http eller https', async () => {
    const result = await guardedGet('file:///etc/passwd')
    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('file:') as unknown as string,
    })
  })

  it('avviser noe som ikke er en URL', async () => {
    const result = await guardedGet('ikke en url')
    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('gyldig URL') as unknown as string,
    })
  })
})

describe('guardedGet — redirect', () => {
  it('følger en redirect og oppgir adressen som faktisk ble lest', async () => {
    const { origin } = await startServer((request, response) => {
      if (request.url === '/start') {
        response.writeHead(302, { location: '/mal' })
        response.end()
        return
      }
      response.writeHead(200, { 'content-type': 'text/plain' })
      response.end('kildeinnhold')
    })

    const result = await guardedGet(`${origin}/start`, { addressPolicy: ALLOW_ALL })

    expect(result).toMatchObject({ status: 'ok', finalUrl: `${origin}/mal` })
    expect(result.status === 'ok' ? Buffer.from(result.bytes).toString() : '').toBe('kildeinnhold')
  })

  // Den viktigste redirect-testen: vakten gjelder hvert hopp, ikke bare det
  // første. Uten den ville en offentlig kilde kunne sende kjøreren videre til
  // et privat mål.
  it('kontrollerer også redirect-målet mot adressevakten', async () => {
    let reachedTarget = false
    const target = await startServer((_request, response) => {
      reachedTarget = true
      response.end('hemmelig')
    })
    const targetOrigin = target.origin
    // En andre server som redirecter til den første. Den første hoppen slippes
    // gjennom av en policy som bare godtar akkurat den serveren; det andre
    // hoppet skal stoppes.
    const redirector = createServer((_request, response) => {
      response.writeHead(302, { location: `${targetOrigin}/hemmelig` })
      response.end()
    })
    await new Promise<void>((resolve) => {
      redirector.listen(0, '127.0.0.1', () => {
        resolve()
      })
    })
    const redirectorAddress = redirector.address()
    if (redirectorAddress === null || typeof redirectorAddress === 'string') {
      throw new Error('serveren fikk ingen port')
    }

    let hop = 0
    const result = await guardedGet(`http://127.0.0.1:${String(redirectorAddress.port)}/`, {
      addressPolicy: () => {
        hop += 1
        return hop === 1 ? { allowed: true } : { allowed: false, reason: 'privat nett' }
      },
    })

    redirector.closeAllConnections()
    await new Promise<void>((resolve) => {
      redirector.close(() => {
        resolve()
      })
    })

    expect(result.status).toBe('error')
    expect(result).toMatchObject({
      message: expect.stringContaining('privat nett') as unknown as string,
    })
    expect(reachedTarget).toBe(false)
  })

  it('gir opp etter for mange hopp framfor å følge en løkke', async () => {
    const { origin } = await startServer((_request, response) => {
      response.writeHead(302, { location: '/videre' })
      response.end()
    })

    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL, maxRedirects: 2 })

    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('videresendt mer enn 2') as unknown as string,
    })
  })

  it('sier fra når en redirect ikke sier hvor den går', async () => {
    const { origin } = await startServer((_request, response) => {
      response.writeHead(302)
      response.end()
    })
    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL })
    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('uten å si hvor den er flyttet') as unknown as string,
    })
  })
})

describe('guardedGet — størrelsesgrensen', () => {
  // Uten grensen kan en kilde bruke opp minnet til kjøreren. Serveren her
  // sender mer enn grensen, og lesingen skal stoppe underveis.
  it('avbryter lesingen når svaret er større enn grensen', async () => {
    const { origin } = await startServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/plain' })
      // Sendes i biter, slik at avbruddet skjer midt i strømmen og ikke først
      // etter at alt er lest.
      for (let index = 0; index < 64; index += 1) {
        response.write('x'.repeat(1024))
      }
      response.end()
    })

    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL, maxBytes: 4096 })

    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('større enn grensen') as unknown as string,
    })
  })

  it('leser et svar som er innenfor grensen', async () => {
    const { origin } = await startServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'application/xml' })
      response.end('<kilde>innhold</kilde>')
    })

    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL, maxBytes: 4096 })

    expect(result).toMatchObject({ status: 'ok', httpStatus: 200, contentType: 'application/xml' })
  })
})

describe('guardedGet — svarkoder og tid', () => {
  it('avviser et svar som ikke er 2xx', async () => {
    const { origin } = await startServer((_request, response) => {
      response.writeHead(404)
      response.end('borte')
    })
    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL })
    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('404') as unknown as string,
    })
  })

  it('gir opp når kilden bruker for lang tid', async () => {
    const { origin } = await startServer(() => {
      // Svarer aldri.
    })
    const result = await guardedGet(origin, { addressPolicy: ALLOW_ALL, timeoutMs: 150 })
    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('for lang tid') as unknown as string,
    })
  })

  // Et tidsavbrudd som bare slutter å vente, er ikke et tidsavbrudd: kilden
  // fortsetter å strømme i bakgrunnen, og en kø med mange kilder samler opp
  // åpne socketer. Forbindelsen skal faktisk rives.
  it('river forbindelsen når hentingen tidsavbrytes', async () => {
    const server = await startServer(() => {
      // Svarer aldri.
    })
    await guardedGet(server.origin, { addressPolicy: ALLOW_ALL, timeoutMs: 150 })
    await vi.waitFor(() => {
      expect(server.openConnections()).toBe(0)
    })
  })

  // Samme regel for en kropp vi aldri skal lese: et feilsvar som strømmer i det
  // uendelige, skal ikke få lov til å gjøre det etter at vi har konkludert.
  it('river forbindelsen når svaret ikke er 2xx, uten å lese kroppen ferdig', async () => {
    const server = await startServer((_request, response) => {
      response.writeHead(500, { 'content-type': 'text/plain' })
      const pump = setInterval(() => {
        response.write('x'.repeat(4096))
      }, 5)
      response.on('close', () => {
        clearInterval(pump)
      })
    })

    const result = await guardedGet(server.origin, { addressPolicy: ALLOW_ALL })

    expect(result.status).toBe('error')
    await vi.waitFor(() => {
      expect(server.openConnections()).toBe(0)
    })
  })

  it('river forbindelsen når svaret er større enn grensen', async () => {
    const server = await startServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/plain' })
      const pump = setInterval(() => {
        response.write('x'.repeat(4096))
      }, 5)
      response.on('close', () => {
        clearInterval(pump)
      })
    })

    const result = await guardedGet(server.origin, { addressPolicy: ALLOW_ALL, maxBytes: 1024 })

    expect(result.status).toBe('error')
    await vi.waitFor(() => {
      expect(server.openConnections()).toBe(0)
    })
  })

  it('sender en identifiserbar User-Agent', async () => {
    let seen: string | undefined
    const { origin } = await startServer((request, response) => {
      seen = request.headers['user-agent']
      response.end('ok')
    })
    await guardedGet(origin, { addressPolicy: ALLOW_ALL })
    expect(seen).toContain('Antidep-ExtractionVerifier')
  })
})
