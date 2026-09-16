import { beforeEach, describe, expect, it } from 'vitest'

import {
  readGatewayConfig,
  readTransportConfig,
  resetMcpAppForTests,
  serveMcpRoute,
} from './index.ts'

// ============================================================================
// Sammensetningen prøvd som det leddet den er
//
// `app.test.ts` prøver protokollen med en grenseflate i minnet, og sier
// dermed ingenting om hva som skjer når miljøet mangler. Nettopp det leddet
// var det som falt i produksjon: appen bygde hele sammensetningen — databasen
// inkludert — før den svarte på noen rute, så én manglende miljøvariabel
// gjorde ALLE ruter til «500», oppdagelsesdokumentene med.
//
// Det er den verste rekkefølgen å feile i. Et MCP-oppsett begynner med at
// klienten leser `/.well-known/oauth-protected-resource` for å finne ut hvor
// den skal autentisere seg. Svarer den ikke, får ingen vite hvorfor.
// ============================================================================

const BASE = 'https://antidep.example'

/** Et miljø uten databaseoppsettet: nøyaktig det produksjon hadde. */
const WITHOUT_DATABASE = { ANTIDEP_MCP_BASE_URL: BASE } as const

function get(route: 'protected-resource-metadata' | 'authorization-server-metadata') {
  return serveMcpRoute(route, new Request(`${BASE}/.well-known/x`), WITHOUT_DATABASE)
}

beforeEach(() => {
  resetMcpAppForTests()
})

describe('oppdagelsesdokumentene uten databaseoppsett', () => {
  it('navngir ressursen, slik at klienten finner autorisasjonstjeneren', async () => {
    const response = await get('protected-resource-metadata')
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({
      resource: `${BASE}/mcp`,
      authorization_servers: [BASE],
    })
  })

  it('navngir autorisasjonstjeneren', async () => {
    const response = await get('authorization-server-metadata')
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ issuer: BASE })
  })
})

describe('rutene som faktisk trenger databasen', () => {
  it('svarer «server_error» uten å røpe hvilken variabel som mangler', async () => {
    const response = await serveMcpRoute(
      'register',
      new Request(`${BASE}/oauth/register`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ redirect_uris: ['https://chatgpt.example/callback'] }),
      }),
      WITHOUT_DATABASE,
    )
    expect(response.status).toBe(500)
    const body = (await response.json()) as Record<string, unknown>
    expect(body['error']).toBe('server_error')
    // Navnet på en miljøvariabel hører hjemme i kjøreloggen, ikke i svaret.
    expect(JSON.stringify(body)).not.toContain('ANTIDEP_SUPABASE_URL')
  })
})

describe('vakten mot en nøkkel som gir for mye', () => {
  // role: service_role — en nøkkel som omgår RLS.
  const SERVICE_ROLE_KEY = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2lnbmF0dXJl'

  it('avviser den fortsatt, selv om den nå leses senere', () => {
    expect(() =>
      readGatewayConfig({
        ANTIDEP_SUPABASE_URL: 'https://db.example',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: SERVICE_ROLE_KEY,
      }),
    ).toThrow('service_role')
  })

  it('slipper aldri en slik nøkkel inn i grenseflaten', async () => {
    const response = await serveMcpRoute(
      'register',
      new Request(`${BASE}/oauth/register`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ redirect_uris: ['https://chatgpt.example/callback'] }),
      }),
      {
        ANTIDEP_MCP_BASE_URL: BASE,
        ANTIDEP_SUPABASE_URL: 'https://db.example',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: SERVICE_ROLE_KEY,
      },
    )
    expect(response.status).toBe(500)
  })
})

describe('de felles variablene i den samme utrullingen', () => {
  const PUBLISHABLE = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.c2lnbmF0dXJl'

  it('leser nettklientens navn når appens egne ikke er satt', () => {
    expect(
      readGatewayConfig({
        VITE_SUPABASE_URL: 'https://prosjekt.supabase.co',
        VITE_SUPABASE_PUBLISHABLE_KEY: PUBLISHABLE,
      }),
    ).toEqual({ supabaseUrl: 'https://prosjekt.supabase.co', publishableKey: PUBLISHABLE })
  })

  it('lar det eksplisitte navnet vinne, slik at en utrulling kan peke et annet sted', () => {
    expect(
      readGatewayConfig({
        ANTIDEP_SUPABASE_URL: 'https://egen.supabase.co',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: PUBLISHABLE,
        VITE_SUPABASE_URL: 'https://nettklienten.supabase.co',
        VITE_SUPABASE_PUBLISHABLE_KEY: 'en annen nøkkel',
      }).supabaseUrl,
    ).toBe('https://egen.supabase.co')
  })

  it('hopper over et navn som er satt til tom tekst', () => {
    expect(
      readGatewayConfig({
        ANTIDEP_SUPABASE_URL: '   ',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: '',
        VITE_SUPABASE_URL: 'https://prosjekt.supabase.co',
        VITE_SUPABASE_PUBLISHABLE_KEY: PUBLISHABLE,
      }).supabaseUrl,
    ).toBe('https://prosjekt.supabase.co')
  })

  it('avviser en nøkkel som gir for mye, uansett hvilket navn den kom under', () => {
    expect(() =>
      readGatewayConfig({
        VITE_SUPABASE_URL: 'https://prosjekt.supabase.co',
        VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_secret_noe',
      }),
    ).toThrow('secret key')
  })

  it('navngir begge mulighetene når ingen av dem er satt', () => {
    expect(() => readGatewayConfig({})).toThrow(/ANTIDEP_SUPABASE_URL eller VITE_SUPABASE_URL/)
  })
})

describe('opprinnelsespolicyen', () => {
  it('kastes ved oppsettet, ikke ved den første forespørselen som avvises', () => {
    expect(() =>
      readTransportConfig({ ANTIDEP_MCP_ALLOWED_ORIGINS: 'ikke en opprinnelse' }),
    ).toThrow('ANTIDEP_MCP_ALLOWED_ORIGINS')
  })

  it('er tom når variabelen ikke er satt', () => {
    expect(readTransportConfig({}).allowedOrigins).toEqual([])
  })
})
