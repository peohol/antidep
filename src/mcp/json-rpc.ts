// ============================================================================
// JSON-RPC 2.0, lest strengt
//
// MCP er JSON-RPC over HTTP. Konvolutten er liten, og den leses her framfor i
// protokollaget, slik at «meldingen var ikke en gyldig forespørsel» og «verktøyet
// svarte med en feil» er to forskjellige ting hele veien ut.
//
// Strengt av samme grunn som resten av det som kommer inn utenfra: en melding
// med et felt vi ikke kjenner, er en melding vi ikke forstår, og den skal si det
// framfor å bli lest med standardverdier.
// ============================================================================

/** Feilkodene JSON-RPC 2.0 definerer. */
export const JSON_RPC_PARSE_ERROR = -32700
export const JSON_RPC_INVALID_REQUEST = -32600
export const JSON_RPC_METHOD_NOT_FOUND = -32601
export const JSON_RPC_INVALID_PARAMS = -32602
export const JSON_RPC_INTERNAL_ERROR = -32603

// MCP-spesifikasjonen reserverer -32020 til -32099 av JSON-RPCs serverfeilområde
// for sine egne koder (2026-07-28, «Error codes»). De tre under er dem denne
// appen kan svare med; -32021 finnes for fullstendighetens skyld og brukes ikke,
// fordi appen ikke krever noen klientevne.
/** Headerne og kroppen sa ikke det samme, eller en påkrevd header manglet. */
export const MCP_HEADER_MISMATCH = -32020
/** Klienten mangler en evne serveren krever. Antidep krever ingen. */
export const MCP_MISSING_REQUIRED_CLIENT_CAPABILITY = -32021
/** Klienten ba om en protokollversjon serveren ikke snakker. */
export const MCP_UNSUPPORTED_PROTOCOL_VERSION = -32022

export type JsonRpcId = string | number | null

export interface JsonRpcRequest {
  readonly id: JsonRpcId
  readonly method: string
  readonly params: Record<string, unknown>
  /** En notifikasjon har ingen id og skal ikke besvares. */
  readonly isNotification: boolean
}

export interface JsonRpcSuccess {
  readonly jsonrpc: '2.0'
  readonly id: JsonRpcId
  readonly result: unknown
}

export interface JsonRpcFailure {
  readonly jsonrpc: '2.0'
  readonly id: JsonRpcId
  readonly error: {
    readonly code: number
    readonly message: string
    /** Maskinlesbare opplysninger om feilen, der spesifikasjonen definerer noen. */
    readonly data?: unknown
  }
}

export type JsonRpcResponse = JsonRpcSuccess | JsonRpcFailure

export function jsonRpcSuccess(id: JsonRpcId, result: unknown): JsonRpcSuccess {
  return { jsonrpc: '2.0', id, result }
}

export function jsonRpcFailure(
  id: JsonRpcId,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcFailure {
  return {
    jsonrpc: '2.0',
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  }
}

/** En melding som ikke kan leses som en forespørsel. */
export class JsonRpcMessageError extends Error {
  readonly code: number
  readonly id: JsonRpcId

  constructor(code: number, message: string, id: JsonRpcId = null) {
    super(message)
    this.name = 'JsonRpcMessageError'
    this.code = code
    this.id = id
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Leser én melding, eller sier hva som er galt med den.
 *
 * `id` leses før alt annet som kan feile, slik at en feil kan besvares med den
 * id-en avsenderen faktisk brukte. Et svar uten id ville vært et svar
 * mottakeren ikke kunne koble til noe.
 */
export function parseJsonRpcMessage(value: unknown): JsonRpcRequest {
  if (!isRecord(value)) {
    throw new JsonRpcMessageError(JSON_RPC_INVALID_REQUEST, 'Meldingen er ikke et JSON-objekt.')
  }

  const rawId = value['id']
  const id: JsonRpcId = typeof rawId === 'string' || typeof rawId === 'number' ? rawId : null
  const isNotification = rawId === undefined || rawId === null

  if (value['jsonrpc'] !== '2.0') {
    throw new JsonRpcMessageError(
      JSON_RPC_INVALID_REQUEST,
      'Meldingen mangler «jsonrpc»: «2.0».',
      id,
    )
  }

  const method = value['method']
  if (typeof method !== 'string' || method.length === 0) {
    throw new JsonRpcMessageError(JSON_RPC_INVALID_REQUEST, 'Meldingen mangler en metode.', id)
  }

  const rawParams = value['params']
  if (rawParams !== undefined && !isRecord(rawParams)) {
    throw new JsonRpcMessageError(
      JSON_RPC_INVALID_PARAMS,
      'Feltet «params» er ikke et JSON-objekt.',
      id,
    )
  }

  return {
    id,
    method,
    params: isRecord(rawParams) ? rawParams : {},
    isNotification,
  }
}
