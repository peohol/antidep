// ============================================================================
// Antideps private MCP-app: én ren funksjon fra forespørsel til svar
//
// Hele appen er `(Request, Route) => Response`. Den holder ingen tilstand, ingen
// hemmelighet og ingen sesjon, og den kan derfor prøves som det den er — et
// protokollendepunkt — uten en server, en port eller en nettleser.
//
// ----------------------------------------------------------------------------
// Rutene
//
//   .well-known/oauth-protected-resource   hvor autorisasjonsserveren er (RFC 9728)
//   .well-known/oauth-authorization-server hva den kan (RFC 8414)
//   /oauth/register                        klientregistrering (RFC 7591)
//   /oauth/authorize                       tilkoblingssiden, der mennesket
//                                          beviser editor-mandat én gang
//   /oauth/token                           kode → token, og fornyelsen
//   /mcp                                   selve protokollendepunktet
//
// ----------------------------------------------------------------------------
// Hvorfor autorisasjonsserveren ligger her og ikke hos en leverandør
//
// Fordi tilstanden hører hjemme i Antideps egen database sammen med resten av
// autorisasjonen, og fordi en ny betalt tjeneste ikke skulle innføres. Serveren
// eier ingen del av den: koder og tokens genereres, hashes og kontrolleres av
// databasen, og dette laget videresender dem (ANTIDEP_CONSTITUTION.md regel 7).
// ============================================================================

import { GatewayError, McpHttpError, UnauthorizedError, type RunnerOutcome } from './errors.ts'
import type { RunnerGateway } from './gateway.ts'
import { renderConnectPage, type ConnectPageFields } from './html.ts'
import {
  JSON_RPC_METHOD_NOT_FOUND,
  JSON_RPC_PARSE_ERROR,
  JsonRpcMessageError,
  MCP_HEADER_MISMATCH,
  MCP_UNSUPPORTED_PROTOCOL_VERSION,
  jsonRpcFailure,
  parseJsonRpcMessage,
  type JsonRpcRequest,
} from './json-rpc.ts'
import { consoleRunnerLogger, type RunnerLogger } from './logging.ts'
import {
  DEFAULT_LEGACY_PROTOCOL_VERSION,
  META_PROTOCOL_VERSION,
  dispatchMcpMessage,
  eraForProtocolVersion,
  isSupportedProtocolVersion,
  SUPPORTED_PROTOCOL_VERSIONS,
  type McpEra,
} from './server.ts'

/** Rutene appen kjenner. Adapteren navngir dem; appen utleder dem ikke av en sti. */
export const MCP_ROUTES = [
  'protected-resource-metadata',
  'authorization-server-metadata',
  'register',
  'authorize',
  'token',
  'mcp',
] as const

export type McpRoute = (typeof MCP_ROUTES)[number]

export const RUNNER_SCOPE = 'antidep.agent-runner'

export interface McpAppDependencies {
  readonly gateway: RunnerGateway
  /**
   * Adressen appen er publisert på, uten skråstrek til slutt.
   *
   * Oppgis eksplisitt der den er kjent, fordi metadatadokumentene og
   * `resource`-parameteren må navngi nøyaktig den samme adressen som klienten
   * kalte. Utledes ellers av forespørselen selv.
   */
  readonly baseUrl?: string | undefined
  readonly logger?: RunnerLogger | undefined
}

function baseUrlOf(request: Request, configured: string | undefined): string {
  if (configured !== undefined && configured.length > 0) {
    return configured.replace(/\/+$/, '')
  }
  const url = new URL(request.url)
  const forwardedHost = request.headers.get('x-forwarded-host')
  const forwardedProto = request.headers.get('x-forwarded-proto')
  const host = forwardedHost ?? url.host
  const proto = forwardedProto ?? url.protocol.replace(':', '')
  return `${proto}://${host}`
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...headers,
    },
  })
}

function publicJson(body: unknown): Response {
  return json(body, 200, {
    'cache-control': 'public, max-age=300',
    'access-control-allow-origin': '*',
  })
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      // Siden har ingen skript og skal ikke kunne rammes inn.
      'content-security-policy':
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
      'x-frame-options': 'DENY',
    },
  })
}

function unauthorized(baseUrl: string, description: string): Response {
  // RFC 9728: svaret sier hvor klienten finner ut hvordan den skal autorisere
  // seg. Uten henvisningen måtte klienten gjette, og en MCP-klient gjetter ikke.
  const challenge =
    `Bearer resource_metadata="${baseUrl}/.well-known/oauth-protected-resource/mcp", ` +
    `scope="${RUNNER_SCOPE}", error="invalid_token", error_description="${description}"`
  return new Response(JSON.stringify({ error: 'invalid_token', error_description: description }), {
    status: 401,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'www-authenticate': challenge,
    },
  })
}

function oauthError(status: number, error: string, description: string): Response {
  return json({ error, error_description: description }, status)
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get('authorization')
  if (header === null) {
    return null
  }
  const match = /^Bearer[ ]+(?<token>[^\s]+)$/i.exec(header)
  return match?.groups?.['token'] ?? null
}

async function formOrJsonBody(request: Request): Promise<Record<string, string>> {
  const contentType = request.headers.get('content-type') ?? ''
  const raw = await request.text()
  if (contentType.includes('application/json')) {
    try {
      const parsed: unknown = JSON.parse(raw)
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        return {}
      }
      return Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>)
          .filter(([, value]) => typeof value === 'string' || typeof value === 'number')
          .map(([key, value]) => [key, String(value)]),
      )
    } catch {
      return {}
    }
  }
  return Object.fromEntries(new URLSearchParams(raw))
}

function connectFields(source: URLSearchParams | Record<string, string>): ConnectPageFields {
  const read = (key: string): string =>
    (source instanceof URLSearchParams ? (source.get(key) ?? '') : (source[key] ?? '')).trim()
  return {
    clientId: read('client_id'),
    redirectUri: read('redirect_uri'),
    codeChallenge: read('code_challenge'),
    codeChallengeMethod: read('code_challenge_method') || 'S256',
    state: read('state'),
    scope: read('scope'),
    resource: read('resource'),
  }
}

/**
 * Den kanoniske adressen tokenet utstedes for (RFC 8707, RFC 9728).
 *
 * Det er denne `resource` må navngi hele veien gjennom OAuth-flyten, og den
 * samme serveren kontrollerer at et access-token faktisk ble utstedt for, før
 * det slipper inn. Uten bindingen kunne et token utstedt for en helt annen
 * MCP-server blitt brukt her — og en tjeneste som tar imot andres tokens, er
 * nettopp den forvirrede stedfortrederen spesifikasjonen advarer mot.
 */
function canonicalResource(baseUrl: string): string {
  return `${baseUrl}/mcp`
}

function missingConnectField(fields: ConnectPageFields, baseUrl: string): string | null {
  if (fields.clientId.length === 0) {
    return 'Forespørselen mangler client_id.'
  }
  if (fields.redirectUri.length === 0) {
    return 'Forespørselen mangler redirect_uri.'
  }
  if (fields.codeChallenge.length === 0) {
    return 'Forespørselen mangler code_challenge. Antidep godtar bare OAuth med PKCE.'
  }
  if (fields.codeChallengeMethod !== 'S256') {
    return 'Antidep godtar bare PKCE med S256.'
  }
  if (fields.resource.length === 0) {
    return 'Forespørselen mangler resource. Et token skal utstedes for én navngitt MCP-server, ikke for hvem som helst.'
  }
  if (fields.resource !== canonicalResource(baseUrl)) {
    return `Forespørselen ber om et token for «${fields.resource}», mens denne appen er ${canonicalResource(baseUrl)}.`
  }
  return null
}

// ---------------------------------------------------------------------------
// Transportlagets kontroll av 2026-revisjonen
//
// Headerne speiler felter fra kroppen, slik at en mellomtjener kan rute uten å
// lese den. Da må de to si det samme: et sted som ruter på headeren mens
// serveren utfører kroppen, er en åpning, og spesifikasjonen krever derfor at
// serveren avviser et avvik med -32020.
// ---------------------------------------------------------------------------
const BASE64_SENTINEL = /^=\?base64\?(?<payload>.*)\?=$/s

/** Leser en headerverdi som kan være base64-innpakket, slik 2026 tillater. */
function decodeHeaderValue(raw: string): string | null {
  const match = BASE64_SENTINEL.exec(raw)
  if (match === null) {
    return raw
  }
  try {
    return new TextDecoder().decode(
      Uint8Array.from(atob(match.groups?.['payload'] ?? ''), (character) =>
        character.charCodeAt(0),
      ),
    )
  } catch {
    return null
  }
}

/**
 * Hva som er galt med de speilede headerne, eller `null`.
 *
 * Bare i den moderne epoken: de eldre revisjonene definerte dem ikke, og å
 * kreve dem der ville vært å avvise en klient som følger sin egen versjon.
 */
function headerProblem(request: Request, message: JsonRpcRequest, declared: string): string | null {
  const version = request.headers.get('mcp-protocol-version')
  if (version === null) {
    return 'Forespørselen mangler MCP-Protocol-Version.'
  }
  const meta = message.params['_meta']
  const inBody =
    typeof meta === 'object' && meta !== null && !Array.isArray(meta)
      ? (meta as Record<string, unknown>)[META_PROTOCOL_VERSION]
      : undefined
  if (typeof inBody !== 'string' || inBody.length === 0) {
    return `Forespørselen mangler ${META_PROTOCOL_VERSION} i params._meta.`
  }
  if (inBody !== declared) {
    return `MCP-Protocol-Version «${declared}» er ikke den samme som ${META_PROTOCOL_VERSION} «${inBody}».`
  }

  const method = request.headers.get('mcp-method')
  if (method === null) {
    return 'Forespørselen mangler Mcp-Method.'
  }
  if (method !== message.method) {
    return `Mcp-Method «${method}» er ikke den samme som metoden «${message.method}» i kroppen.`
  }

  if (message.method === 'tools/call') {
    const raw = request.headers.get('mcp-name')
    if (raw === null) {
      return 'Forespørselen mangler Mcp-Name.'
    }
    const name = decodeHeaderValue(raw)
    if (name === null) {
      return 'Mcp-Name er base64-merket, men lar seg ikke dekode.'
    }
    if (name !== message.params['name']) {
      return `Mcp-Name «${name}» er ikke det samme som verktøynavnet i kroppen.`
    }
  }

  return null
}

// ---------------------------------------------------------------------------
// Rutene
// ---------------------------------------------------------------------------
function protectedResourceMetadata(baseUrl: string): Response {
  return publicJson({
    resource: `${baseUrl}/mcp`,
    authorization_servers: [baseUrl],
    scopes_supported: [RUNNER_SCOPE],
    bearer_methods_supported: ['header'],
    resource_name: 'Antidep agentarbeid',
    resource_documentation: `${baseUrl}/agentarbeid`,
  })
}

function authorizationServerMetadata(baseUrl: string): Response {
  return publicJson({
    issuer: baseUrl,
    authorization_endpoint: `${baseUrl}/oauth/authorize`,
    token_endpoint: `${baseUrl}/oauth/token`,
    registration_endpoint: `${baseUrl}/oauth/register`,
    scopes_supported: [RUNNER_SCOPE],
    response_types_supported: ['code'],
    response_modes_supported: ['query'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    // Bare S256. En klient uten PKCE ville hvilt på at redirect-adressen aldri
    // lakk, og det er ikke en antakelse Antidep skal bygge på.
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    // RFC 8707: tokens utstedes for én navngitt ressurs, og klienten skal si
    // hvilken. RFC 9207: autorisasjonssvaret navngir utstederen sin.
    resource_indicators_supported: true,
    authorization_response_iss_parameter_supported: true,
    service_documentation: `${baseUrl}/agentarbeid`,
  })
}

async function registerClient(request: Request, deps: McpAppDependencies): Promise<Response> {
  let body: unknown
  try {
    body = await request.json()
  } catch {
    return oauthError(400, 'invalid_client_metadata', 'Forespørselen er ikke gyldig JSON.')
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return oauthError(400, 'invalid_client_metadata', 'Forespørselen er ikke et JSON-objekt.')
  }
  const record = body as Record<string, unknown>
  const rawUris = record['redirect_uris']
  if (!Array.isArray(rawUris) || rawUris.some((uri) => typeof uri !== 'string')) {
    return oauthError(400, 'invalid_redirect_uri', 'redirect_uris må være en liste med adresser.')
  }
  const name = record['client_name']

  const registered = await deps.gateway.registerClient({
    clientName: typeof name === 'string' && name.trim().length > 0 ? name.trim() : 'MCP-klient',
    redirectUris: rawUris as string[],
  })

  return json(
    {
      client_id: registered.clientId,
      client_name: typeof name === 'string' ? name : 'MCP-klient',
      redirect_uris: registered.redirectUris,
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
      scope: RUNNER_SCOPE,
    },
    201,
  )
}

async function authorize(
  request: Request,
  deps: McpAppDependencies,
  baseUrl: string,
): Promise<Response> {
  const url = new URL(request.url)

  if (request.method === 'GET') {
    const fields = connectFields(url.searchParams)
    return html(renderConnectPage(fields, missingConnectField(fields, baseUrl)))
  }

  const form = await formOrJsonBody(request)
  const fields = connectFields(form)
  const missing = missingConnectField(fields, baseUrl)
  if (missing !== null) {
    return html(renderConnectPage(fields, missing), 400)
  }

  const pairingCode = (form['pairing_code'] ?? '').trim()
  if (pairingCode.length === 0) {
    return html(renderConnectPage(fields, 'Du må lime inn tilkoblingskoden.'), 400)
  }

  let grant
  try {
    grant = await deps.gateway.authorize({
      pairingCode,
      clientId: fields.clientId,
      redirectUri: fields.redirectUri,
      codeChallenge: fields.codeChallenge,
      codeChallengeMethod: fields.codeChallengeMethod,
      resource: fields.resource,
    })
  } catch (error) {
    // Avvisningen er alltid den samme setningen fra databasen, og den skiller
    // ikke mellom en ukjent kode og en ukjent klient. Den vises som den er.
    const problem =
      error instanceof GatewayError
        ? error.message
        : 'Tilkoblingen kunne ikke fullføres. Prøv med en ny kode.'
    return html(renderConnectPage(fields, problem), 400)
  }

  // Først her er adressen bevist å tilhøre en registrert klient. En omdirigering
  // før den kontrollen ville gjort siden til en åpen viderekobling.
  const target = new URL(fields.redirectUri)
  target.searchParams.set('code', grant.authorizationCode)
  if (fields.state.length > 0) {
    target.searchParams.set('state', fields.state)
  }
  // RFC 9207: svaret navngir utstederen sin, slik at klienten kan se at koden
  // kom fra den autorisasjonsserveren den faktisk spurte — og ikke fra en annen
  // som rakk å svare først.
  target.searchParams.set('iss', baseUrl)
  return new Response(null, {
    status: 302,
    headers: { location: target.toString(), 'cache-control': 'no-store' },
  })
}

async function token(
  request: Request,
  deps: McpAppDependencies,
  baseUrl: string,
): Promise<Response> {
  const form = await formOrJsonBody(request)
  const grantType = form['grant_type'] ?? ''
  const clientId = (form['client_id'] ?? '').trim()

  if (clientId.length === 0) {
    return oauthError(400, 'invalid_client', 'client_id mangler.')
  }

  // `resource` skal følge tokenforespørselen og ikke bare autorisasjonen
  // (RFC 8707). Uten den her kunne en kode utstedt for denne appen blitt vekslet
  // inn i et token uten publikum — og et token uten publikum er et token som
  // passer overalt.
  const resource = (form['resource'] ?? '').trim()
  if (resource.length === 0) {
    return oauthError(400, 'invalid_target', 'resource mangler.')
  }
  if (resource !== canonicalResource(baseUrl)) {
    return oauthError(
      400,
      'invalid_target',
      `Denne autorisasjonsserveren utsteder bare tokens for ${canonicalResource(baseUrl)}.`,
    )
  }

  try {
    if (grantType === 'authorization_code') {
      const tokens = await deps.gateway.exchangeCode({
        code: (form['code'] ?? '').trim(),
        codeVerifier: form['code_verifier'] ?? '',
        clientId,
        redirectUri: (form['redirect_uri'] ?? '').trim(),
        resource,
      })
      return json({
        access_token: tokens.accessToken,
        token_type: 'Bearer',
        expires_in: tokens.expiresIn,
        refresh_token: tokens.refreshToken,
        scope: tokens.scope,
      })
    }

    if (grantType === 'refresh_token') {
      const tokens = await deps.gateway.refresh({
        refreshToken: (form['refresh_token'] ?? '').trim(),
        clientId,
        resource,
      })
      return json({
        access_token: tokens.accessToken,
        token_type: 'Bearer',
        expires_in: tokens.expiresIn,
        refresh_token: tokens.refreshToken,
        scope: tokens.scope,
      })
    }
  } catch (error) {
    if (error instanceof GatewayError) {
      return oauthError(400, 'invalid_grant', error.message)
    }
    throw error
  }

  return oauthError(
    400,
    'unsupported_grant_type',
    'Bare authorization_code og refresh_token støttes.',
  )
}

async function mcpEndpoint(
  request: Request,
  deps: McpAppDependencies,
  baseUrl: string,
): Promise<{
  readonly response: Response
  readonly tool?: string
  readonly outcome: RunnerOutcome | 'auth_failed' | 'bad_request'
}> {
  if (request.method === 'GET' || request.method === 'DELETE') {
    // Spesifikasjonen tillater begge deler: serveren har ingen serverinitierte
    // meldinger og ingen sesjon å avslutte.
    return {
      response: new Response(null, { status: 405, headers: { allow: 'POST' } }),
      outcome: 'bad_request',
    }
  }
  if (request.method !== 'POST') {
    return {
      response: new Response(null, { status: 405, headers: { allow: 'POST' } }),
      outcome: 'bad_request',
    }
  }

  // Epoken avgjøres her, av headeren, og ikke av et håndtrykk. En forespørsel
  // uten headeren leses som 2025-03-26: headeren kom først i 2025-06-18, og en
  // klient som aldri fikk vite at den fantes, skal ikke avvises for å mangle den.
  const declared = request.headers.get('mcp-protocol-version') ?? DEFAULT_LEGACY_PROTOCOL_VERSION
  if (!isSupportedProtocolVersion(declared)) {
    return {
      response: json(
        jsonRpcFailure(
          null,
          MCP_UNSUPPORTED_PROTOCOL_VERSION,
          `Antidep snakker ikke protokollversjonen «${declared}».`,
          { supported: [...SUPPORTED_PROTOCOL_VERSIONS], requested: declared },
        ),
        400,
      ),
      outcome: 'bad_request',
    }
  }
  const era: McpEra = eraForProtocolVersion(declared)

  const accessToken = bearerToken(request)
  if (accessToken === null) {
    return {
      response: unauthorized(baseUrl, 'Forespørselen mangler et access-token.'),
      outcome: 'auth_failed',
    }
  }

  // Tokenet kontrolleres på hver forespørsel, og ikke bare i verktøykallet.
  // Uten dette ville et utløpt eller tilbaketrukket token sett ut som en levende
  // tilkobling helt til det første kallet — og en MCP-klient trenger nettopp
  // avslaget for å vite at den skal fornye.
  let identity
  try {
    // Publikum kontrolleres sammen med tokenet: databasen godtar det bare
    // dersom det faktisk ble utstedt for nettopp denne adressen (RFC 8707).
    identity = await deps.gateway.identify(accessToken, canonicalResource(baseUrl))
  } catch (error) {
    if (error instanceof GatewayError || error instanceof UnauthorizedError) {
      return {
        response: unauthorized(baseUrl, 'Tilkoblingen er ikke autentisert.'),
        outcome: 'auth_failed',
      }
    }
    throw error
  }

  let message
  try {
    const body: unknown = await request.json()
    if (Array.isArray(body)) {
      // Antidep svarer på én melding om gangen. En samling ville krevd et
      // svarsett med delvise feil, og verktøyflaten her er for liten til at
      // gevinsten forsvarer den formen.
      return {
        response: json(
          jsonRpcFailure(null, JSON_RPC_PARSE_ERROR, 'Denne appen tar imot én melding om gangen.'),
          400,
        ),
        outcome: 'bad_request',
      }
    }
    message = parseJsonRpcMessage(body)
  } catch (error) {
    if (error instanceof JsonRpcMessageError) {
      return {
        response: json(jsonRpcFailure(error.id, error.code, error.message), 400),
        outcome: 'bad_request',
      }
    }
    return {
      response: json(
        jsonRpcFailure(null, JSON_RPC_PARSE_ERROR, 'Forespørselen er ikke gyldig JSON.'),
        400,
      ),
      outcome: 'bad_request',
    }
  }

  // Headerne speiler kroppen fra 2026-07-28. Avviket avvises her, før noe
  // utføres: et sted som ruter på headeren mens serveren utfører kroppen, er en
  // åpning, og det er nettopp den denne kontrollen lukker.
  if (era === 'modern') {
    const problem = headerProblem(request, message, declared)
    if (problem !== null) {
      return {
        response: json(jsonRpcFailure(message.id, MCP_HEADER_MISMATCH, problem), 400),
        outcome: 'bad_request',
      }
    }
  }

  try {
    const dispatched = await dispatchMcpMessage(message, era, accessToken, identity, deps)
    if (dispatched.response === null) {
      return { response: new Response(null, { status: 202 }), outcome: 'ok' }
    }
    // En ukjent metode er 404 i den moderne epoken. Statusen er det klienten
    // bruker til å skille en server som ikke kjenner kallet, fra en som ikke
    // ligger her i det hele tatt.
    const unknownMethod =
      era === 'modern' &&
      'error' in dispatched.response &&
      dispatched.response.error.code === JSON_RPC_METHOD_NOT_FOUND
    const result = {
      response: json(dispatched.response, unknownMethod ? 404 : 200),
      outcome: dispatched.trace?.outcome ?? 'ok',
    }
    return dispatched.trace === null ? result : { ...result, tool: dispatched.trace.tool }
  } catch (error) {
    if (error instanceof UnauthorizedError) {
      return { response: unauthorized(baseUrl, error.message), outcome: 'auth_failed' }
    }
    if (error instanceof GatewayError && error.code === '42501') {
      // Databasen avviste tokenet. Det er en autorisasjonsfeil og ikke en
      // verktøyfeil, og klienten skal få vite at den må koble til på nytt.
      return { response: unauthorized(baseUrl, error.message), outcome: 'auth_failed' }
    }
    throw error
  }
}

/**
 * Hele appen.
 *
 * Adapteren sier hvilken rute forespørselen traff; appen utleder den ikke av en
 * sti, fordi stien kan være omskrevet av plattformen foran den.
 */
export async function handleMcpRequest(
  route: McpRoute,
  request: Request,
  deps: McpAppDependencies,
): Promise<Response> {
  const started = Date.now()
  const logger = deps.logger ?? consoleRunnerLogger
  const baseUrl = baseUrlOf(request, deps.baseUrl)

  let response: Response
  let tool: string | undefined
  let outcome: RunnerOutcome | 'auth_failed' | 'bad_request' = 'ok'

  try {
    if (request.method === 'OPTIONS') {
      response = new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers':
            'authorization, content-type, mcp-protocol-version, mcp-method, mcp-name',
          'access-control-max-age': '600',
        },
      })
    } else {
      switch (route) {
        case 'protected-resource-metadata':
          response = protectedResourceMetadata(baseUrl)
          break
        case 'authorization-server-metadata':
          response = authorizationServerMetadata(baseUrl)
          break
        case 'register':
          if (request.method !== 'POST') {
            throw new McpHttpError(405, 'Bare POST.')
          }
          response = await registerClient(request, deps)
          break
        case 'authorize':
          if (request.method !== 'GET' && request.method !== 'POST') {
            throw new McpHttpError(405, 'Bare GET og POST.')
          }
          response = await authorize(request, deps, baseUrl)
          break
        case 'token':
          if (request.method !== 'POST') {
            throw new McpHttpError(405, 'Bare POST.')
          }
          response = await token(request, deps, baseUrl)
          break
        case 'mcp': {
          const handled = await mcpEndpoint(request, deps, baseUrl)
          response = handled.response
          tool = handled.tool
          outcome = handled.outcome
          break
        }
      }
    }
  } catch (error) {
    outcome = 'server_error'
    if (error instanceof McpHttpError) {
      response = json({ error: 'invalid_request', error_description: error.message }, error.status)
    } else if (error instanceof GatewayError) {
      response = json({ error: 'server_error', error_description: error.message }, 502)
    } else {
      // Teksten fra en ukjent feil kan bære hva som helst, og den skal ikke ut.
      response = json(
        {
          error: 'server_error',
          error_description: 'Antidep kunne ikke fullføre forespørselen.',
        },
        500,
      )
    }
  }

  logger({
    route,
    tool,
    outcome,
    status: response.status,
    durationMs: Date.now() - started,
  })

  return response
}
