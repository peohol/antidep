// ============================================================================
// Authorization Server Metadata (/.well-known/oauth-authorization-server, RFC 8414)
//
// Adapteren er tynn med vilje: den sier hvilken rute forespørselen traff, og
// ingenting annet. Hele appen ligger i src/mcp og kan prøves uten en server.
// ============================================================================

import { serveMcpRoute } from '../../src/mcp/index.ts'

export default {
  fetch(request: Request): Promise<Response> {
    return serveMcpRoute('authorization-server-metadata', request, process.env)
  },
}
