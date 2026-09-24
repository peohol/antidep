import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

import { HANDOFF_ROLES, type HandoffRole } from '../agents/agent-task.ts'
import { handleMcpRequest, type McpRoute } from './app.ts'
import {
  LEGACY_MCP_ENTRY,
  MCP_APP_ENTRIES,
  entryForMcpPath,
  entryForMetadataPath,
  entryPathFor,
  type McpAppEntry,
} from './entries.ts'
import {
  createFakeGateway,
  FAKE_ACCESS_TOKEN,
  FAKE_AUTHORIZATION_CODE,
  FAKE_BASE_URL,
  FAKE_CLIENT_ID,
  FAKE_PAIRING_CODE,
  FAKE_REDIRECT_URI,
  fakeResourceFor,
  type FakeGateway,
} from './fake-gateway.ts'
import { silentRunnerLogger, type RunnerLogRecord } from './logging.ts'

// ============================================================================
// App-inngangene prøvd som det ChatGPT ser: seks adresser, én backend
//
// Hver inngang er sin egen app for plattformen, og sin egen ressurs for OAuth.
// Prøvene går gjennom `handleMcpRequest` med ekte `Request`-objekter på hver
// inngangs egen adresse, slik at det er stien — og ikke en parameter en prøve
// satte — som avgjør hvilken app kallet kom til.
//
// Grensen prøvene holder fast ved: adressen gir ingen fullmakt. Rollen følger
// tokenet, et token virker bare på inngangen det ble utstedt for, og en
// tilkobling for et annet ledd avvises av inngangen framfor å få mer.
// ============================================================================

const BASE = FAKE_BASE_URL
const CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'

const THE_FIVE_TOOLS = [
  'claim_agent_task',
  'get_agent_task',
  'list_pending_agent_tasks',
  'release_agent_task',
  'submit_agent_answer',
]

/** Guiden som forteller redaktøren hvilke apper som skal opprettes. */
const SETUP_GUIDE = 'docs/CHATGPT_WORKSPACE_AGENT.md'

/** De seks adressene som skal opprettes som apper i ChatGPT, skrevet ut. */
const THE_SIX_PATHS = [
  '/mcp/source-discovery',
  '/mcp/source-quality-assessment',
  '/mcp/evidence-extraction',
  '/mcp/claim-synthesis',
  '/mcp/evidence-assessment',
  '/mcp/monograph-answer',
]

function send(
  route: McpRoute,
  request: Request,
  gateway: FakeGateway,
  logger: (record: RunnerLogRecord) => void = silentRunnerLogger,
): Promise<Response> {
  return handleMcpRequest(route, request, { gateway, baseUrl: BASE, logger })
}

function rpcAt(
  path: string,
  method: string,
  params: Record<string, unknown> = {},
  token: string | null = FAKE_ACCESS_TOKEN,
  origin: string | null = null,
): Request {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
  }
  if (token !== null) {
    headers['authorization'] = `Bearer ${token}`
  }
  if (origin !== null) {
    headers['origin'] = origin
  }
  return new Request(`${BASE}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
}

async function toolNamesAt(path: string, gateway: FakeGateway): Promise<string[]> {
  const response = await send('mcp', rpcAt(path, 'tools/list'), gateway)
  expect(response.status).toBe(200)
  const body = (await response.json()) as { result: { tools: { name: string }[] } }
  return body.result.tools.map((tool) => tool.name).sort()
}

function authorizeAt(resource: string, pairingCode = FAKE_PAIRING_CODE): Request {
  return new Request(`${BASE}/oauth/authorize`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: FAKE_CLIENT_ID,
      redirect_uri: FAKE_REDIRECT_URI,
      code_challenge: CHALLENGE,
      code_challenge_method: 'S256',
      state: 'inngang',
      resource,
      pairing_code: pairingCode,
    }).toString(),
  })
}

function tokenAt(resource: string): Request {
  return new Request(`${BASE}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: FAKE_AUTHORIZATION_CODE,
      code_verifier: 'en-verifier',
      client_id: FAKE_CLIENT_ID,
      redirect_uri: FAKE_REDIRECT_URI,
      resource,
    }).toString(),
  })
}

function entryFor(role: HandoffRole): McpAppEntry {
  const entry = MCP_APP_ENTRIES.find((candidate) => candidate.agentRole === role)
  if (entry === undefined) {
    throw new Error(`Ingen inngang for ${role}.`)
  }
  return entry
}

describe('de seks inngangene', () => {
  it('finnes, én per agentledd som kan settes ut, på de adressene dokumentasjonen gir', () => {
    expect(MCP_APP_ENTRIES.map((entry) => entry.path).sort()).toEqual([...THE_SIX_PATHS].sort())
    expect(MCP_APP_ENTRIES.map((entry) => entry.agentRole)).toEqual([...HANDOFF_ROLES])
    expect(new Set(MCP_APP_ENTRIES.map((entry) => entry.path)).size).toBe(6)
  })

  it('har de navnene appene skal ha i ChatGPT', () => {
    expect(Object.fromEntries(MCP_APP_ENTRIES.map((entry) => [entry.path, entry.appName]))).toEqual(
      {
        '/mcp/source-discovery': 'Antidep – Kildeoppdagelse',
        '/mcp/source-quality-assessment': 'Antidep – Dekningskontroll',
        '/mcp/evidence-extraction': 'Antidep – Evidensekstraksjon',
        '/mcp/claim-synthesis': 'Antidep – Påstandssyntese',
        '/mcp/evidence-assessment': 'Antidep – Evidensvurdering',
        '/mcp/monograph-answer': 'Antidep – Monografisvar',
      },
    )
  })

  it('står i oppsettsguiden slik koden har dem, rad for rad', () => {
    const row = /^\|\s*`([a-z_]+)`\s*\|\s*(.+?)\s*\|\s*`https:\/\/[^/`]+(\/mcp\/[a-z-]+)`\s*\|$/
    const documented = readFileSync(SETUP_GUIDE, 'utf8')
      .split('\n')
      .map((line) => row.exec(line.trim()))
      .filter((match) => match !== null)
      .map(([, agentRole, appName, path]) => `${agentRole} | ${appName} | ${path}`)
    expect(documented.sort()).toEqual(
      MCP_APP_ENTRIES.map(
        ({ agentRole, appName, path }) => `${agentRole} | ${appName} | ${path}`,
      ).sort(),
    )
  })

  it('holder /mcp som kildeoppdagelsens inngang, med de samme metadataene som før', () => {
    expect(LEGACY_MCP_ENTRY.path).toBe('/mcp')
    expect(LEGACY_MCP_ENTRY.agentRole).toBe('source_discovery')
    expect(LEGACY_MCP_ENTRY.resourceName).toBe('Antidep agentarbeid')
  })

  it('leser inngangen av stien, og av ingenting annet', () => {
    expect(entryForMcpPath('/mcp')).toBe(LEGACY_MCP_ENTRY)
    expect(entryForMcpPath('/api/mcp')).toBe(LEGACY_MCP_ENTRY)
    expect(entryForMcpPath('/mcp/source-quality-assessment')?.agentRole).toBe(
      'source_quality_assessment',
    )
    // Ingen tilnærming: en sti som ikke er en inngang, er ikke en.
    for (const path of [
      '/mcp/',
      '/mcp/source_quality_assessment',
      '/mcp/Source-Discovery',
      '/mcp/source-discovery/',
      '/mcp/source-discovery/extra',
      '/mcp/extraction_verification',
      '/api/mcpx',
      '/',
    ]) {
      expect(entryForMcpPath(path), path).toBeNull()
    }
  })

  it('finner metadatadokumentet for hver inngang der RFC 9728 sier det står', () => {
    expect(entryForMetadataPath('/.well-known/oauth-protected-resource')).toBe(LEGACY_MCP_ENTRY)
    expect(entryForMetadataPath('/.well-known/oauth-protected-resource/mcp')).toBe(LEGACY_MCP_ENTRY)
    for (const entry of MCP_APP_ENTRIES) {
      expect(entryForMetadataPath(`/.well-known/oauth-protected-resource${entry.path}`)).toBe(entry)
    }
    expect(entryForMetadataPath('/.well-known/oauth-protected-resource/mcp/ukjent')).toBeNull()
    expect(entryForMetadataPath('/.well-known/oauth-protected-resource/annet')).toBeNull()
  })
})

describe('verktøyflaten på hver inngang', () => {
  it('gir nøyaktig de fem verktøyene på hver inngang, og ikke ett til', async () => {
    for (const role of HANDOFF_ROLES) {
      const names = await toolNamesAt(entryPathFor(role), createFakeGateway({ role }))
      expect(names, role).toEqual(THE_FIVE_TOOLS)
    }
  })

  it('gir den samme flaten på den opprinnelige /mcp', async () => {
    const gateway = createFakeGateway({ role: 'source_discovery', resource: `${BASE}/mcp` })
    expect(await toolNamesAt('/mcp', gateway)).toEqual(THE_FIVE_TOOLS)
  })

  it('lar kildeoppdagelsens tilkobling på /mcp hente arbeidet sitt som før', async () => {
    const gateway = createFakeGateway({ role: 'source_discovery', resource: `${BASE}/mcp` })
    const response = await send(
      'mcp',
      rpcAt('/mcp', 'tools/call', { name: 'list_pending_agent_tasks', arguments: {} }),
      gateway,
    )
    expect(response.status).toBe(200)
    const body = (await response.json()) as { result: { structuredContent: unknown } }
    expect(body.result.structuredContent).toMatchObject({ agent_role: 'source_discovery' })
  })

  it('svarer 404 på en inngang som ikke finnes, før tokenet leses', async () => {
    const gateway = createFakeGateway()
    const response = await send('mcp', rpcAt('/mcp/ukjent', 'tools/list'), gateway)
    expect(response.status).toBe(404)
    expect(gateway.claims).toBe(0)
  })
})

describe('tokenet og rollen, ikke adressen', () => {
  // Hver kjører er koblet til sin egen inngang. Tokenet er utstedt for den
  // inngangens adresse, og databasen avviser det mot enhver annen.
  it('lar ikke et token for ett ledd autentisere på noen annen inngang', async () => {
    for (const role of HANDOFF_ROLES) {
      const gateway = createFakeGateway({ role })
      for (const other of [...MCP_APP_ENTRIES, LEGACY_MCP_ENTRY]) {
        if (other.agentRole === role && other !== LEGACY_MCP_ENTRY) {
          continue
        }
        const response = await send(
          'mcp',
          rpcAt(other.path, 'tools/call', { name: 'claim_agent_task', arguments: {} }),
          gateway,
        )
        expect(response.status, `${role} på ${other.path}`).toBe(401)
      }
      expect(gateway.claims, role).toBe(0)
    }
  })

  it('gir tokenet arbeid i sitt eget ledd på sin egen inngang', async () => {
    const gateway = createFakeGateway({ role: 'source_quality_assessment' })
    const response = await send(
      'mcp',
      rpcAt('/mcp/source-quality-assessment', 'tools/call', {
        name: 'list_pending_agent_tasks',
        arguments: {},
      }),
      gateway,
    )
    expect(response.status).toBe(200)
    const body = (await response.json()) as { result: { structuredContent: unknown } }
    expect(body.result.structuredContent).toMatchObject({ agent_role: 'source_quality_assessment' })
  })

  // En tilkobling for dekningskontrollen koblet til kildeoppdagelsens app — det
  // inngangene finnes for å forhindre. Tokenet er gyldig for adressen, men
  // inngangen avviser det før meldingen er lest.
  it('avviser en tilkobling for et annet ledd, uten å utføre noe', async () => {
    const gateway = createFakeGateway({
      role: 'source_quality_assessment',
      resource: fakeResourceFor('source_discovery'),
    })
    const lines: RunnerLogRecord[] = []
    const response = await send(
      'mcp',
      rpcAt('/mcp/source-discovery', 'tools/call', { name: 'claim_agent_task', arguments: {} }),
      gateway,
      (record) => lines.push(record),
    )
    expect(response.status).toBe(403)
    const body = (await response.json()) as { error: { message: string } }
    expect(body.error.message).toContain('source_quality_assessment')
    expect(body.error.message).toContain('Antidep – Kildeoppdagelse')
    expect(gateway.claims).toBe(0)
    expect(gateway.recorded).toEqual([])
    expect(lines.map((line) => [line.outcome, line.entry])).toEqual([
      ['wrong_role', '/mcp/source-discovery'],
    ])
  })

  it('avviser et annet ledds tilkobling også på den opprinnelige /mcp', async () => {
    const gateway = createFakeGateway({ role: 'evidence_extraction', resource: `${BASE}/mcp` })
    const response = await send('mcp', rpcAt('/mcp', 'tools/list'), gateway)
    expect(response.status).toBe(403)
  })
})

describe('OAuth for hver inngang', () => {
  it('peker hver inngangs metadatadokument på dens egen ressurs og den felles autorisasjonsserveren', async () => {
    for (const entry of MCP_APP_ENTRIES) {
      const response = await send(
        'protected-resource-metadata',
        new Request(`${BASE}/.well-known/oauth-protected-resource${entry.path}`),
        createFakeGateway(),
      )
      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({
        resource: `${BASE}${entry.path}`,
        authorization_servers: [BASE],
        scopes_supported: ['antidep.agent-runner'],
        bearer_methods_supported: ['header'],
        resource_name: entry.appName,
        resource_documentation: `${BASE}/agentarbeid`,
      })
    }
  })

  it('har ikke noe metadatadokument for en inngang som ikke finnes', async () => {
    const response = await send(
      'protected-resource-metadata',
      new Request(`${BASE}/.well-known/oauth-protected-resource/mcp/ukjent`),
      createFakeGateway(),
    )
    expect(response.status).toBe(404)
  })

  it('sender klienten til inngangens eget metadatadokument når tokenet mangler', async () => {
    for (const entry of [...MCP_APP_ENTRIES, LEGACY_MCP_ENTRY]) {
      const response = await send(
        'mcp',
        rpcAt(entry.path, 'tools/list', {}, null),
        createFakeGateway(),
      )
      expect(response.status).toBe(401)
      expect(response.headers.get('www-authenticate')).toContain(
        `resource_metadata="${BASE}/.well-known/oauth-protected-resource${entry.path}"`,
      )
    }
  })

  it('beskriver den felles autorisasjonsserveren med de samme endepunktene som før', async () => {
    const response = await send(
      'authorization-server-metadata',
      new Request(`${BASE}/.well-known/oauth-authorization-server`),
      createFakeGateway(),
    )
    expect(await response.json()).toMatchObject({
      issuer: BASE,
      authorization_endpoint: `${BASE}/oauth/authorize`,
      token_endpoint: `${BASE}/oauth/token`,
      registration_endpoint: `${BASE}/oauth/register`,
      resource_indicators_supported: true,
    })
  })

  // Hver app registrerer seg selv, kobler til med sin egen kjørers kode og får
  // et token for sin egen adresse. At tokenene er forskjellige og at en klient
  // er en annen, er databasens sak og prøves i `npm run db:test:mcp`; her
  // prøves at hele flyten går for hver inngang, og at tokenet den gir, ikke
  // virker noe annet sted.
  it('går hele tilkoblingen for hver inngang, og tokenet virker bare der', async () => {
    for (const role of HANDOFF_ROLES) {
      const entry = entryFor(role)
      const resource = `${BASE}${entry.path}`
      const gateway = createFakeGateway({ role })

      const page = await send(
        'authorize',
        new Request(
          `${BASE}/oauth/authorize?client_id=${FAKE_CLIENT_ID}` +
            `&redirect_uri=${encodeURIComponent(FAKE_REDIRECT_URI)}` +
            `&code_challenge=${CHALLENGE}&code_challenge_method=S256` +
            `&resource=${encodeURIComponent(resource)}`,
        ),
        gateway,
      )
      expect(await page.text(), role).toContain(entry.appName)

      const authorized = await send('authorize', authorizeAt(resource), gateway)
      expect(authorized.status, role).toBe(302)
      const location = new URL(authorized.headers.get('location') ?? '')
      expect(location.searchParams.get('code')).toBe(FAKE_AUTHORIZATION_CODE)
      expect(location.searchParams.get('iss')).toBe(BASE)

      const tokens = await send('token', tokenAt(resource), gateway)
      expect(tokens.status, role).toBe(200)
      expect(await toolNamesAt(entry.path, gateway)).toEqual(THE_FIVE_TOOLS)

      const elsewhere = MCP_APP_ENTRIES.filter((other) => other !== entry)
      for (const other of elsewhere) {
        const response = await send('mcp', rpcAt(other.path, 'tools/list'), gateway)
        expect(response.status, `${role} på ${other.path}`).toBe(401)
      }
    }
  })

  it('gir ingen kode når koden hører til en kjører for et annet ledd', async () => {
    const gateway = createFakeGateway({
      role: 'source_quality_assessment',
      resource: fakeResourceFor('source_discovery'),
    })
    const response = await send(
      'authorize',
      authorizeAt(fakeResourceFor('source_discovery')),
      gateway,
    )
    expect(response.status).toBe(400)
    expect(response.headers.get('location')).toBeNull()
    const html = await response.text()
    expect(html).toContain('Antidep – Kildeoppdagelse')
    expect(html).toContain('source_quality_assessment')
    expect(html).not.toContain(FAKE_AUTHORIZATION_CODE)
  })

  it('gir ingen kode for den opprinnelige /mcp til et annet ledd enn kildeoppdagelsen', async () => {
    const gateway = createFakeGateway({ role: 'evidence_extraction', resource: `${BASE}/mcp` })
    const response = await send('authorize', authorizeAt(`${BASE}/mcp`), gateway)
    expect(response.status).toBe(400)
    expect(response.headers.get('location')).toBeNull()
  })

  it('kobler fortsatt kildeoppdagelsen til den opprinnelige /mcp', async () => {
    const gateway = createFakeGateway({ role: 'source_discovery', resource: `${BASE}/mcp` })
    const authorized = await send('authorize', authorizeAt(`${BASE}/mcp`), gateway)
    expect(authorized.status).toBe(302)
    const tokens = await send('token', tokenAt(`${BASE}/mcp`), gateway)
    expect(tokens.status).toBe(200)
  })

  it('utsteder ingen token for en adresse under /mcp som ikke er en inngang', async () => {
    const response = await send(
      'token',
      tokenAt(`${BASE}/mcp/ukjent`),
      createFakeGateway({ role: 'source_discovery' }),
    )
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ error: 'invalid_target' })
  })
})

describe('transportgrensene på hver inngang', () => {
  it('avviser en fremmed opprinnelse på hver inngang før tokenet leses', async () => {
    for (const entry of [...MCP_APP_ENTRIES, LEGACY_MCP_ENTRY]) {
      const gateway = createFakeGateway({ role: entry.agentRole })
      const response = await send(
        'mcp',
        rpcAt(
          entry.path,
          'tools/call',
          { name: 'claim_agent_task', arguments: {} },
          FAKE_ACCESS_TOKEN,
          'https://angriper.example',
        ),
        gateway,
      )
      expect(response.status, entry.path).toBe(403)
      expect(response.headers.get('access-control-allow-origin')).toBeNull()
      expect(gateway.claims).toBe(0)
    }
  })

  it('ekkoer ingen wildcard på noen inngangs metadatadokument', async () => {
    for (const entry of MCP_APP_ENTRIES) {
      const response = await send(
        'protected-resource-metadata',
        new Request(`${BASE}/.well-known/oauth-protected-resource${entry.path}`, {
          headers: { origin: 'https://angriper.example' },
        }),
        createFakeGateway(),
      )
      expect(response.status).toBe(403)
      expect(response.headers.get('access-control-allow-origin')).toBeNull()
    }
  })

  it('bærer de samme sidegrensene på tilkoblingssiden for hver inngang', async () => {
    for (const entry of MCP_APP_ENTRIES) {
      const response = await send(
        'authorize',
        new Request(
          `${BASE}/oauth/authorize?client_id=${FAKE_CLIENT_ID}` +
            `&redirect_uri=${encodeURIComponent(FAKE_REDIRECT_URI)}` +
            `&code_challenge=${CHALLENGE}&code_challenge_method=S256` +
            `&resource=${encodeURIComponent(`${BASE}${entry.path}`)}`,
        ),
        createFakeGateway(),
      )
      const csp = response.headers.get('content-security-policy') ?? ''
      expect(csp).toContain("default-src 'none'")
      expect(csp).toContain(`form-action 'self' ${new URL(FAKE_REDIRECT_URI).origin}`)
      expect(csp).toContain("frame-ancestors 'none'")
      expect(response.headers.get('x-frame-options')).toBe('DENY')
      expect(response.headers.get('referrer-policy')).toBe('same-origin')
    }
  })
})
